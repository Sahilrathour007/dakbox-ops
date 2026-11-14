-- =====================================================================
-- Migration 013: automatic dispatch, widening truck search, smarter return trips
-- Run once in Supabase -> SQL Editor, AFTER migration_012 (safe to run again).
--
-- 1. Search like a ride app: the nearest free truck within 25 km, else 50, 100, 150 km
--    (settings.search_rings_km, capped by max_distance_km). A driver who declines, or does not
--    answer within settings.offer_timeout_min (10 min), is not offered that parcel again for 12 hours;
--    the offer goes to the next truck.
-- 2. Automatic dispatch: auto_dispatch() expires unanswered offers and sends every trip that is
--    ready under the fill rule. Runs every minute (pg_cron) while settings.auto_dispatch is on;
--    the ops page also runs it while open.
-- 3. Return trips: from where the truck unloads, home directly or home via one more warehouse
--    (at most return_max_detour_pct extra km). The plan that earns most after extra diesel,
--    maintenance and driver pay is offered; the breakdown is shown to ops and the driver.
--    Tolls are not in this comparison (shown as such).
-- =====================================================================

alter table public.settings add column if not exists search_rings_km numeric[] not null default '{25,50,100,150}';
alter table public.settings add column if not exists offer_timeout_min int not null default 10;
alter table public.settings add column if not exists auto_dispatch boolean not null default true;
alter table public.settings add column if not exists last_auto_dispatch_at timestamptz;
alter table public.settings add column if not exists return_max_detour_pct numeric not null default 25;

-- Postal regions: '20' (centred near Aligarh) also covered Kanpur (208) and Noida/Ghaziabad (201), so parcels
-- TO those cities were given Agra as destination warehouse. 3-digit regions for them (approximate centres).
insert into public.pin_regions (prefix, place, lat, lon) values
 ('201','Ghaziabad / Noida',28.62,77.40),('202','Aligarh',27.88,78.08),('203','Bulandshahr',28.40,77.85),
 ('204','Hathras',27.60,78.05),('205','Mainpuri / Firozabad',27.23,79.02),('206','Etawah / Auraiya',26.78,79.02),
 ('207','Etah / Kasganj',27.56,78.66),('208','Kanpur',26.45,80.33),('209','Kanpur Dehat / Unnao',26.50,80.30),
 ('421','Thane / Bhiwandi',19.28,73.05),('400','Mumbai',19.08,72.88),('411','Pune',18.52,73.86),
 ('122','Gurugram',28.46,77.03),('121','Faridabad',28.41,77.32),('110','Delhi',28.61,77.21),
 ('226','Lucknow',26.85,80.95),('282','Agra',27.18,78.01),('302','Jaipur',26.91,75.79),('380','Ahmedabad',23.02,72.57),
 ('500','Hyderabad',17.39,78.49),('560','Bengaluru',12.97,77.59),('600','Chennai',13.08,80.27),('700','Kolkata',22.57,88.36)
on conflict (prefix) do update set place = excluded.place, lat = excluded.lat, lon = excluded.lon;

-- waiting parcels whose destination warehouse changed: new destination and route (legs already done stay)
update public.orders o set dest_wh = n.wh
  from (select awb, public.warehouse_for_pincode(delivery_pincode) as wh from public.orders
         where status in ('booked','in_transit') and truck_no is null) n
 where o.awb = n.awb and n.wh is not null and o.dest_wh is distinct from n.wh;
update public.orders o
   set route = case when o.leg_no <= 1 then p.r else o.route[1:o.leg_no] || p.r[2:] end, next_wh = p.r[2]
  from (select awb, public.plan_route(cur_wh, dest_wh) as r from public.orders
         where status in ('booked','in_transit') and truck_no is null and cur_wh is not null and dest_wh is not null) p
 where o.awb = p.awb and p.r is not null and array_length(p.r, 1) >= 2
   and o.status in ('booked','in_transit') and o.truck_no is null
   and o.route[o.leg_no:] is distinct from p.r;

-- who was offered what and did not take it (declined or no answer)
create table if not exists public.offer_log (
  id       bigserial primary key,
  awb      text not null references public.orders(awb) on delete cascade,
  truck_no text not null references public.trucks(truck_no) on delete cascade,
  outcome  text not null check (outcome in ('declined','expired')),
  at       timestamptz not null default now()
);
create index if not exists offer_log_awb_idx on public.offer_log (awb, truck_no, at);
alter table public.offer_log enable row level security;
drop policy if exists staff_read on public.offer_log;
create policy staff_read on public.offer_log for select to authenticated using (true);
revoke all on public.offer_log from anon;

-- a return load knows the truck's home, so the drive home is costed even after an extra stop
alter table public.parcel_legs add column if not exists home_wh text references public.warehouses(code);

-- the return plan offered to a driver (shown on the driver page)
create table if not exists public.return_plans (
  id         bigserial primary key,
  truck_no   text not null references public.trucks(truck_no) on delete cascade,
  at_wh      text not null references public.warehouses(code),
  home_wh    text not null references public.warehouses(code),
  via_wh     text references public.warehouses(code),
  plan       jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists return_plans_truck_idx on public.return_plans (truck_no, created_at desc);
alter table public.return_plans enable row level security;
drop policy if exists staff_read on public.return_plans;
create policy staff_read on public.return_plans for select to authenticated using (true);
revoke all on public.return_plans from anon;

-- parcels waiting on one lane that fit in p_cap kg, oldest first
create or replace function public.lane_fit(p_from text, p_to text, p_cap numeric)
returns table (awb text, kg numeric, revenue numeric) language sql stable set search_path = public as $$
  select q.awb, q.charged_kg, public.leg_revenue(q.awb, p_from, p_to)
    from (select o.awb, o.charged_kg, sum(o.charged_kg) over (order by o.created_at, o.awb) as run_kg
            from public.orders o
           where o.cur_wh = p_from and o.next_wh = p_to and o.status in ('booked','in_transit') and o.truck_no is null) q
   where q.run_kg <= p_cap
$$;

-- Return plan for a truck: from where it unloads to its home, directly or via one more warehouse.
-- Every option is costed against driving home empty (same formulas as the Money tab, tolls excluded).
create or replace function public.plan_return(p_truck text)
returns jsonb language plpgsql stable set search_path = public as $$
declare s record; tr public.trucks; lg record; at_wh text; home text; a record; h record; c record;
        d_direct numeric; base_cost numeric; opts jsonb := '[]'; best jsonb; o jsonb;
        stops jsonb; seg record; segs text[][]; i int; km_road numeric; fuel numeric; maint numeric; drv numeric;
        rev numeric; kgs numeric; awbs text[]; npar int; stop_list jsonb; total_rev numeric; total_fuel numeric;
        total_maint numeric; total_drv numeric; total_km numeric; via text;
begin
  select * into s from public.settings where id = 1;
  select * into tr from public.trucks where truck_no = p_truck;
  if tr.truck_no is null then return null; end if;
  -- home = start of the truck's latest outward trip; the truck is (or will be) where its latest leg ends
  select l.from_wh, l.to_wh, l.assigned_at into lg from public.parcel_legs l
   where l.truck_no = p_truck and not l.backhaul order by l.assigned_at desc limit 1;
  if lg.from_wh is null then return null; end if;
  home := lg.from_wh;
  select l.to_wh into at_wh from public.parcel_legs l where l.truck_no = p_truck order by l.assigned_at desc, l.id desc limit 1;
  if at_wh is null or at_wh = home then return null; end if;
  select * into a from public.warehouses where code = at_wh;
  select * into h from public.warehouses where code = home;
  d_direct := public.km(a.lat, a.lon, h.lat, h.lon);
  base_cost := round(d_direct * s.road_factor / s.km_per_l_empty * s.diesel_price + d_direct * s.road_factor * s.maint_per_km);

  -- candidate routes home: direct, or via any warehouse with at most return_max_detour_pct extra km
  for via in
    select null::text
    union all
    select w.code from public.warehouses w
     where w.active and w.code not in (at_wh, home)
       and public.km(a.lat, a.lon, w.lat, w.lon) + public.km(w.lat, w.lon, h.lat, h.lon) - d_direct <= d_direct * s.return_max_detour_pct / 100
  loop
    stop_list := '[]'; total_rev := 0; total_fuel := 0; total_maint := 0; total_drv := 0; total_km := 0;
    for seg in
      select x.f, x.t, x.ord from (values (at_wh, coalesce(via, home), 1), (via, home, 2)) x(f, t, ord) where x.f is not null order by x.ord
    loop
      select coalesce(sum(lf.revenue), 0), coalesce(sum(lf.kg), 0), coalesce(array_agg(lf.awb), '{}'), count(*)
        into rev, kgs, awbs, npar from public.lane_fit(seg.f, seg.t, tr.capacity_kg) lf;
      select public.km(w1.lat, w1.lon, w2.lat, w2.lon) into km_road from public.warehouses w1, public.warehouses w2 where w1.code = seg.f and w2.code = seg.t;
      drv := case when npar > 0 then round(s.trip_pay_base + s.trip_pay_per_km * km_road) else 0 end;
      km_road := km_road * s.road_factor;
      fuel := round(km_road / case when npar > 0 then s.km_per_l_loaded else s.km_per_l_empty end * s.diesel_price);
      maint := round(km_road * s.maint_per_km);
      stop_list := stop_list || jsonb_build_object('from', seg.f, 'to', seg.t,
                     'from_name', (select name from public.warehouses where code = seg.f), 'to_name', (select name from public.warehouses where code = seg.t),
                     'km', round(km_road), 'parcels', npar, 'kg', kgs, 'revenue', round(rev), 'driver', drv, 'awbs', to_jsonb(awbs));
      total_rev := total_rev + rev; total_fuel := total_fuel + fuel; total_maint := total_maint + maint;
      total_drv := total_drv + drv; total_km := total_km + km_road;
    end loop;
    continue when total_rev = 0;
    o := jsonb_build_object('via', via, 'via_name', (select name from public.warehouses where code = via),
           'stops', stop_list, 'km', round(total_km), 'extra_km', round(total_km - d_direct * s.road_factor),
           'revenue', round(total_rev), 'fuel', total_fuel, 'maintenance', total_maint, 'driver', total_drv,
           'cost', total_fuel + total_maint + total_drv, 'extra_cost', total_fuel + total_maint + total_drv - base_cost,
           'gain', round(total_rev) - (total_fuel + total_maint + total_drv - base_cost));
    opts := opts || o;
  end loop;

  select coalesce(jsonb_agg(x order by (x->>'gain')::numeric desc), '[]') into opts from jsonb_array_elements(opts) x;
  -- best: the most gain; a detour only if it earns more than driving home empty, the direct lane even at a small loss
  -- (moving those parcels any other way costs a whole separate truck)
  select x into best from jsonb_array_elements(opts) x
   where (x->>'gain')::numeric > 0 or x->>'via' is null
   order by (x->>'gain')::numeric desc limit 1;
  return jsonb_build_object('truck_no', p_truck, 'at_wh', at_wh, 'home_wh', home, 'at_name', a.name, 'home_name', h.name,
           'km_direct', round(d_direct * s.road_factor), 'empty_return_cost', base_cost,
           'best', best, 'options', opts, 'tolls', 'not included');
end $$;

-- Offer the best return plan's first stop to the truck (the next stop is offered when it unloads there).
drop function if exists public.offer_return_load(text,text[]);
create or replace function public.offer_return_load(p_truck text, p_awbs text[] default null, p_at timestamptz default now())
returns int language plpgsql security definer set search_path = public as $$
declare s record; p jsonb; b jsonb; st jsonb; picked text[]; n int; nstops int;
begin
  select * into s from public.settings where id = 1;
  perform 1 from public.trucks where truck_no = p_truck for update;
  -- one return load at a time
  if exists (select 1 from public.parcel_legs l where l.truck_no = p_truck and l.backhaul and l.unloaded_at is null) then return 0; end if;
  p := public.plan_return(p_truck);
  b := p->'best';
  if b is null then return 0; end if;
  st := b->'stops'->0;
  select array_agg(x) into picked from jsonb_array_elements_text(st->'awbs') x where p_awbs is null or x = any(p_awbs);
  n := coalesce(array_length(picked, 1), 0);
  if n = 0 then return 0; end if;
  nstops := jsonb_array_length(b->'stops');
  update public.orders set truck_no = p_truck, status = 'pickup_assigned', assigned_at = p_at, accepted_at = null,
         pickup_distance_km = 0, driver_pay = round((st->>'driver')::numeric / n)
   where awb = any(picked) and status in ('booked','in_transit') and truck_no is null;
  insert into public.parcel_legs (awb, leg_no, from_wh, to_wh, truck_no, assigned_at, to_wh_km, driver_pay, revenue_share, backhaul, home_wh)
  select o.awb, o.leg_no, o.cur_wh, o.next_wh, p_truck, o.assigned_at, 0, o.driver_pay, public.leg_revenue(o.awb, o.cur_wh, o.next_wh), true, p->>'home_wh'
    from public.orders o where o.awb = any(picked) and o.truck_no = p_truck;
  update public.trucks t set load_kg = t.load_kg + (select coalesce(sum(charged_kg), 0) from public.orders where awb = any(picked))
   where t.truck_no = p_truck;
  insert into public.return_plans (truck_no, at_wh, home_wh, via_wh, plan) values (p_truck, p->>'at_wh', p->>'home_wh', b->>'via', p);
  insert into public.order_events (awb, status, truck_no, note, by_user, at)
  select awb, 'pickup_assigned', p_truck,
         'Return load offered to ' || p_truck || case when nstops > 1 then ' (stop 1 of ' || nstops || ', via ' || (b->>'via') || ')' else '' end,
         auth.uid(), p_at
    from public.orders where awb = any(picked) and truck_no = p_truck;
  return n;
end $$;

-- Ops: every real truck between its outward trip and home, with its return plan
drop function if exists public.return_load_matches();
create or replace function public.return_load_matches()
returns table (truck_no text, driver_name text, driver_phone text, stage text, last_ping_at timestamptz,
               plan jsonb, offered int, accepted int)
language sql stable set search_path = public as $$
  with trip as (
    select l.truck_no, l.from_wh, l.to_wh, l.assigned_at, bool_or(l.loaded_at is not null) as loaded,
           bool_and(l.unloaded_at is not null) as unloaded, max(l.unloaded_at) as unloaded_at
      from public.parcel_legs l where not l.backhaul group by 1, 2, 3, 4),
  last_trip as (
    select distinct on (t.truck_no) t.* from trip t join public.trucks tr on tr.truck_no = t.truck_no and not tr.is_simulated
     order by t.truck_no, t.assigned_at desc)
  select lt.truck_no, tr.driver_name, tr.driver_phone,
         case when not lt.loaded then 'Going to load at ' || a.name
              when not lt.unloaded then 'Driving to ' || b.name
              else 'Unloaded at ' || b.name || ', going home' end,
         tr.last_ping_at,
         -- while a return load is open, show the plan the driver was offered; otherwise the best plan now
         coalesce((select rp.plan from public.return_plans rp
                    where rp.truck_no = lt.truck_no and rp.created_at >= lt.assigned_at
                      and exists (select 1 from public.parcel_legs l where l.truck_no = lt.truck_no and l.backhaul and l.unloaded_at is null)
                    order by rp.created_at desc limit 1),
                  public.plan_return(lt.truck_no)),
         (select count(*) from public.parcel_legs l join public.orders o on o.awb = l.awb
           where l.truck_no = lt.truck_no and l.backhaul and l.assigned_at >= lt.assigned_at and o.status = 'pickup_assigned')::int,
         (select count(*) from public.parcel_legs l join public.orders o on o.awb = l.awb
           where l.truck_no = lt.truck_no and l.backhaul and l.assigned_at >= lt.assigned_at and o.status in ('driver_accepted','picked_up'))::int
    from last_trip lt
    join public.trucks tr on tr.truck_no = lt.truck_no
    join public.warehouses a on a.code = lt.from_wh
    join public.warehouses b on b.code = lt.to_wh
   where (not lt.unloaded or lt.unloaded_at > now() - interval '24 hours')
     and not exists (select 1 from public.gps_pings p where p.truck_no = lt.truck_no and lt.unloaded_at is not null
                       and p.recorded_at > lt.unloaded_at and public.km(p.lat, p.lon, a.lat, a.lon) <= 0.5)
   order by lt.unloaded desc, lt.truck_no
$$;

-- Unanswered offers expire; ready trips are sent. Safe to run any time (one run at a time).
create or replace function public.auto_dispatch()
returns jsonb language plpgsql security definer set search_path = public as $$
declare s record; o record; n_exp int := 0; n_sent int := 0; back_to text;
begin
  if not pg_try_advisory_xact_lock(4343) then return jsonb_build_object('skipped', true); end if;
  select * into s from public.settings where id = 1;
  for o in select * from public.orders
            where status = 'pickup_assigned' and assigned_at < now() - make_interval(mins => s.offer_timeout_min)
              and not coalesce((select is_simulated from public.trucks t where t.truck_no = orders.truck_no), false)
            for update skip locked loop
    back_to := case when o.leg_no > 1 then 'in_transit' else 'booked' end;
    insert into public.offer_log (awb, truck_no, outcome) values (o.awb, o.truck_no, 'expired');
    update public.trucks set load_kg = greatest(0, load_kg - o.charged_kg) where truck_no = o.truck_no;
    delete from public.parcel_legs where awb = o.awb and leg_no = o.leg_no and truck_no = o.truck_no and loaded_at is null;
    update public.orders set status = back_to, truck_no = null, assigned_at = null, accepted_at = null,
           driver_pay = null, pickup_distance_km = null where awb = o.awb;
    insert into public.order_events (awb, status, truck_no, note)
    values (o.awb, back_to, o.truck_no, 'Offer expired: no answer from ' || o.truck_no || ' in ' || s.offer_timeout_min || ' min');
    n_exp := n_exp + 1;
  end loop;
  if s.auto_dispatch then n_sent := public.confirm_allocations(null, null); end if;
  update public.settings set last_auto_dispatch_at = now() where id = 1;
  return jsonb_build_object('expired', n_exp, 'sent', n_sent);
end $$;

-- Dispatch: widening search, declines and expired offers remembered
create or replace function public.suggest_allocations(p_max_km numeric default null, p_fresh_min int default null)
returns table (awb text, truck_no text, distance_km numeric, reason text)
language plpgsql stable security definer set search_path = public as $$
declare
  s record; o record; best record; near record; maxkm numeric; freshmin int;
  used_kg jsonb := '{}'::jsonb;      -- truck -> kg added in this run
  lane_of jsonb := '{}'::jsonb;      -- truck -> route it took in this run
  lane text; t text; fk numeric; ring numeric; prev_ring numeric;
begin
  select * into s from public.settings where id = 1;
  maxkm := coalesce(p_max_km, s.max_distance_km);
  freshmin := coalesce(p_fresh_min, s.gps_fresh_minutes);

  for o in
    select x.*, w.lat as wlat, w.lon as wlon, w.name as wname
      from (select ord.*, min(ord.created_at) over (partition by ord.cur_wh, ord.next_wh) as lane_first
              from public.orders ord where ord.status in ('booked','in_transit') and ord.truck_no is null) x
      left join public.warehouses w on w.code = x.cur_wh
     order by x.lane_first, x.cur_wh, x.next_wh, x.created_at
  loop
    awb := o.awb; truck_no := null; distance_km := null;
    if o.cur_wh is null then
      reason := 'No warehouse for this pickup. Add one near pincode ' || o.pickup_pincode;
      return next; continue;
    end if;
    if o.next_wh is null then
      reason := case when o.dest_wh is null then 'No warehouse for delivery pincode ' || o.delivery_pincode
                     else 'Delivered from this warehouse: no truck leg needed' end;
      return next; continue;
    end if;
    lane := o.cur_wh || '>' || o.next_wh;

    -- a truck already heading for this route in this run, with room
    select je.key into t from jsonb_each_text(lane_of) je where je.value = lane
      and (select tr.capacity_kg - tr.load_kg from public.trucks tr where tr.truck_no = je.key)
          - coalesce((used_kg ->> je.key)::numeric, 0) >= o.charged_kg
      limit 1;
    if t is not null then
      select tr.truck_no as tno, public.km(o.wlat, o.wlon, tr.last_lat, tr.last_lon) as d into best
        from public.trucks tr where tr.truck_no = t;
    else
      select tr.truck_no as tno, public.km(o.wlat, o.wlon, tr.last_lat, tr.last_lon) as d into best
        from public.trucks tr
       where tr.status = 'available' and not tr.is_simulated
         and tr.last_ping_at >= now() - make_interval(mins => freshmin)
         and public.km(o.wlat, o.wlon, tr.last_lat, tr.last_lon) <= maxkm
         and not (lane_of ? tr.truck_no)
         and not exists (select 1 from public.orders a where a.truck_no = tr.truck_no
                          and a.status in ('pickup_assigned','driver_accepted','picked_up'))
         and tr.capacity_kg - tr.load_kg >= o.charged_kg
         -- not a truck that declined this parcel or let the offer expire in the last 12 hours
         and not exists (select 1 from public.offer_log ol where ol.awb = o.awb and ol.truck_no = tr.truck_no
                          and ol.at > now() - interval '12 hours')
       order by 2 limit 1;
    end if;

    if best.tno is not null then
      truck_no := best.tno; distance_km := round(best.d::numeric, 1);
      fk := coalesce((used_kg ->> best.tno)::numeric, 0) + o.charged_kg;
      used_kg := used_kg || jsonb_build_object(best.tno, fk);
      lane_of := lane_of || jsonb_build_object(best.tno, lane);
      -- search like a ride app: 25 km, then 50, 100, 150 (capped by the max distance)
      select min(r) into ring from unnest(s.search_rings_km || maxkm) r where r >= best.d and r <= maxkm;
      select max(r) into prev_ring from unnest(s.search_rings_km) r where r < ring;
      reason := case when t is not null then 'Joins the same truck on this route'
                     else 'Nearest free truck to ' || o.wname || ', ' || round(best.d::numeric) || ' km'
                          || case when prev_ring is not null then ' (none within ' || prev_ring || ' km, search widened to ' || ring || ' km)' else '' end end;
      t := null; best := null;
      return next; continue;
    end if;
    t := null;

    -- explain why nothing fits, using the nearest truck to the warehouse
    select tr.truck_no as tno, public.km(o.wlat, o.wlon, tr.last_lat, tr.last_lon) as d,
           tr.status, tr.last_ping_at, tr.capacity_kg - tr.load_kg - coalesce((used_kg ->> tr.truck_no)::numeric, 0) as free,
           exists (select 1 from public.orders a where a.truck_no = tr.truck_no
                    and a.status in ('pickup_assigned','driver_accepted','picked_up')) as busy
      into near from public.trucks tr where tr.last_lat is not null and not tr.is_simulated
     order by public.km(o.wlat, o.wlon, tr.last_lat, tr.last_lon) limit 1;
    reason := case
      when near.tno is null then 'No truck has sent GPS yet'
      when near.d > maxkm then 'No free truck within ' || maxkm || ' km of ' || o.wname || ' (searched ' || array_to_string(s.search_rings_km, ', ') || ' km). Nearest: ' || near.tno || ', ' || round(near.d::numeric) || ' km'
      when exists (select 1 from public.offer_log ol where ol.awb = o.awb and ol.truck_no = near.tno and ol.at > now() - interval '12 hours')
        then 'Nearest truck ' || near.tno || ' declined or did not answer; waiting for another truck'
      when near.status <> 'available' then 'Nearest truck ' || near.tno || ' is ' || replace(near.status, '_', ' ')
      when near.last_ping_at < now() - make_interval(mins => freshmin) then 'Nearest truck ' || near.tno || ': GPS last seen ' || round(extract(epoch from now() - near.last_ping_at) / 60) || ' min ago'
      when near.busy or lane_of ? near.tno then 'Nearest truck ' || near.tno || ' is already on another trip'
      else 'Nearest truck ' || near.tno || ' has only ' || round(near.free) || ' kg free' end;
    return next;
  end loop;
end $$;

create or replace function public.driver_action(p_awb text, p_action text)
returns text language plpgsql security definer set search_path = public as $$
declare o public.orders; new_status text;
begin
  select * into o from public.orders where awb = p_awb for update;
  if o.awb is null then raise exception 'This job no longer exists'; end if;
  if p_action = 'accept' and o.status = 'pickup_assigned' then
    update public.orders set status = 'driver_accepted', accepted_at = now() where awb = p_awb;
    new_status := 'driver_accepted';
  elsif p_action = 'decline' and o.status in ('pickup_assigned','driver_accepted') then
    insert into public.offer_log (awb, truck_no, outcome) values (p_awb, o.truck_no, 'declined');
    update public.trucks set load_kg = greatest(0, load_kg - o.charged_kg) where truck_no = o.truck_no;
    delete from public.parcel_legs where awb = p_awb and leg_no = o.leg_no and truck_no = o.truck_no and loaded_at is null;
    new_status := case when o.leg_no > 1 then 'in_transit' else 'booked' end;
    update public.orders set status = new_status, truck_no = null, assigned_at = null, accepted_at = null,
           driver_pay = null, pickup_distance_km = null where awb = p_awb;
  else
    raise exception 'This job has already moved on. Pull down to refresh.';
  end if;
  insert into public.order_events (awb, status, truck_no, note, by_user)
  values (p_awb, new_status, o.truck_no, 'Driver: ' || p_action, auth.uid());
  return new_status;
end $$;

-- Money: return loads with an extra stop end at home
drop view if exists public.rule_flags;
drop view if exists public.trip_pnl;
create view public.trip_pnl with (security_invoker = true) as
with s as (select * from public.settings where id = 1),
t as (
  select l.truck_no, l.from_wh as origin_wh, l.to_wh as dest_wh, l.assigned_at,
         l.truck_no || '|' || l.from_wh || '|' || l.to_wh || '|' || floor(extract(epoch from l.assigned_at))::bigint as trip_key,
         count(*)::int as parcels, sum(o.charged_kg) as kg, sum(l.revenue_share) as revenue_legs,
         coalesce(sum(l.driver_pay), 0) as driver_pay, coalesce(max(l.to_wh_km), 0) as to_wh_km,
         bool_and(l.unloaded_at is not null) as completed, bool_or(l.backhaul) as backhaul, max(l.home_wh) as home_wh
    from public.parcel_legs l join public.orders o on o.awb = l.awb
   where l.truck_no is not null
   group by l.truck_no, l.from_wh, l.to_wh, l.assigned_at),
x as (
  select t.*, wo.name as from_name, wd.name as to_name, tr.capacity_kg, tr.toll_class,
         coalesce(public.km(wo.lat, wo.lon, wd.lat, wd.lon), 0) as straight_km,
         lv.total_min as load_dwell_min, lv.last_scan_at as loaded_at,
         uv.total_min as unload_dwell_min, uv.last_scan_at as unloaded_at,
         least(case when not t.backhaul then ret.at
                    when coalesce(t.home_wh, t.dest_wh) = t.dest_wh then uv.last_scan_at
                    else reth.at end, nx.at) as returned_at,
         c.fuel_rs as fuel_actual, c.tolls_rs as tolls_actual,
         s.diesel_price, s.km_per_l_loaded, s.km_per_l_empty, s.maint_per_km, s.line_haul_share, s.road_factor
    from t
    join public.warehouses wo on wo.code = t.origin_wh
    left join public.warehouses wd on wd.code = t.dest_wh
    join public.trucks tr on tr.truck_no = t.truck_no
    cross join s
    left join lateral (select v.total_min, v.last_scan_at from public.visit_times v where v.truck_no = t.truck_no and v.warehouse = t.origin_wh
                         and v.purpose = 'load' and v.created_at >= t.assigned_at - interval '1 hour' order by v.id limit 1) lv on true
    left join lateral (select v.total_min, v.last_scan_at from public.visit_times v where v.truck_no = t.truck_no and v.warehouse = t.dest_wh
                         and v.purpose = 'unload' and v.created_at >= t.assigned_at - interval '1 hour' order by v.id limit 1) uv on true
    -- back at the origin warehouse after unloading = trip finished (includes the return leg)
    left join lateral (select min(p.recorded_at) as at from public.gps_pings p where p.truck_no = t.truck_no
                         and uv.last_scan_at is not null and p.recorded_at > uv.last_scan_at
                         and public.km(p.lat, p.lon, wo.lat, wo.lon) <= 0.5) ret on true
    -- a return load that stops on the way: it ends when the truck is back home
    left join lateral (select min(p.recorded_at) as at from public.gps_pings p join public.warehouses hw on hw.code = t.home_wh
                        where p.truck_no = t.truck_no and uv.last_scan_at is not null and p.recorded_at > uv.last_scan_at
                          and public.km(p.lat, p.lon, hw.lat, hw.lon) <= 0.5) reth on true
    -- the truck's next job starts: this trip's km and tolls stop here (no km counted twice)
    left join lateral (select min(l2.assigned_at) as at from public.parcel_legs l2
                        where l2.truck_no = t.truck_no and l2.assigned_at > t.assigned_at) nx on true
    left join public.trip_costs c on c.trip_key = t.trip_key),
g as (
  select x.*, coalesce(x.returned_at, now()) as window_end,
         gp.total_km, gp.loaded_km, gp.moving_km, gp.moving_h,
         te.tolls, te.toll_count, te.missing_rates, te.xway_km_uncosted, te.xway_uncosted, te.xway_nh
    from x
    left join lateral (
      select sum(d) as total_km,
             sum(d) filter (where ts > x.loaded_at and ts <= coalesce(x.unloaded_at, now())) as loaded_km,
             sum(d) filter (where d / nullif(h, 0) between 5 and 120) as moving_km,
             sum(h) filter (where d / nullif(h, 0) between 5 and 120) as moving_h
        from (select public.km(lag(p.lat) over w, lag(p.lon) over w, p.lat, p.lon) as d,
                     extract(epoch from p.recorded_at - lag(p.recorded_at) over w) / 3600 as h,
                     p.recorded_at as ts
                from public.gps_pings p
               where p.truck_no = x.truck_no and p.recorded_at >= x.assigned_at
                 and p.recorded_at <= coalesce(x.returned_at, now())
              window w as (order by p.recorded_at)) seg
       where d is not null and d < 20) gp on true
    left join lateral (
      select sum(e.amount) as tolls, count(*) filter (where e.amount > 0 or not pl.closed_loop)::int as toll_count,
             bool_or(e.rate_missing and not pl.closed_loop) as missing_rates,
             sum(coalesce(e.km, 0)) filter (where pl.closed_loop and e.rate_missing) as xway_km_uncosted,
             bool_or(pl.closed_loop and e.rate_missing) as xway_uncosted,
             string_agg(distinct public.nh_key(pl.nh), ', ') filter (where pl.closed_loop and e.rate_missing) as xway_nh
        from public.toll_events e join public.toll_plazas pl on pl.id = e.plaza_id
       where e.truck_no = x.truck_no and e.at >= x.assigned_at and e.at <= coalesce(x.returned_at, now())) te on true),
y as (
  select g.*,
         -- km: from GPS when the truck sent positions, otherwise an estimate
         (coalesce(g.total_km, 0) > 0) as km_from_gps,
         case when coalesce(g.total_km, 0) > 0 then g.total_km
              when g.backhaul then g.straight_km * g.road_factor   -- a return load ends at home
              else g.to_wh_km + 2 * g.straight_km * g.road_factor end as km_total,
         case when coalesce(g.total_km, 0) > 0 then coalesce(g.loaded_km, 0)
              else g.straight_km * g.road_factor end as km_loaded
    from g),
z as (
  select y.*, y.km_total - y.km_loaded as km_empty,
         round(y.revenue_legs) as revenue,
         round((y.km_loaded / y.km_per_l_loaded + (y.km_total - y.km_loaded) / y.km_per_l_empty) * y.diesel_price) as fuel_calc,
         round(y.km_total * y.maint_per_km) as maintenance,
         greatest(0.1, extract(epoch from (y.window_end - y.assigned_at)) / 3600) as cycle_h
    from y)
select z.trip_key, z.truck_no, z.toll_class, z.backhaul, z.origin_wh, z.dest_wh, z.from_name, z.to_name, z.assigned_at,
       z.completed, z.returned_at is not null as returned,
       z.parcels, z.kg, z.capacity_kg, round(z.kg / z.capacity_kg * 100, 1) as fill_pct,
       round(z.km_total::numeric, 1) as km_total, round(z.km_loaded::numeric, 1) as km_loaded,
       round(z.km_empty::numeric, 1) as km_empty, z.km_from_gps,
       case when z.moving_h > 0 then round((z.moving_km / z.moving_h)::numeric, 1) end as avg_speed_kmh,
       z.revenue,
       coalesce(z.fuel_actual, z.fuel_calc) as fuel, z.fuel_actual is not null as fuel_is_actual, z.diesel_price,
       coalesce(z.tolls_actual, z.tolls, 0) as tolls, coalesce(z.toll_count, 0) as toll_count,
       case when z.tolls_actual is not null then 'entered' when z.toll_count > 0 then 'nhai' else 'none' end as tolls_source,
       coalesce(z.missing_rates, false) as toll_rate_missing,
       coalesce(z.xway_uncosted, false) as expressway_uncosted, round(coalesce(z.xway_km_uncosted, 0)::numeric, 1) as expressway_km_uncosted, z.xway_nh as expressway_nh,
       z.maintenance, z.driver_pay,
       coalesce(z.fuel_actual, z.fuel_calc) + coalesce(z.tolls_actual, z.tolls, 0) + z.maintenance + z.driver_pay as cost,
       z.revenue - (coalesce(z.fuel_actual, z.fuel_calc) + coalesce(z.tolls_actual, z.tolls, 0) + z.maintenance + z.driver_pay) as profit,
       round(z.cycle_h::numeric, 1) as cycle_hours,
       round((z.revenue - (coalesce(z.fuel_actual, z.fuel_calc) + coalesce(z.tolls_actual, z.tolls, 0) + z.maintenance + z.driver_pay)) / z.cycle_h) as per_truck_hour,
       coalesce(z.load_dwell_min, 0) + coalesce(z.unload_dwell_min, 0) as dwell_min,
       case when z.kg > 0 and z.revenue > 0 then
         round((coalesce(z.fuel_actual, z.fuel_calc) + coalesce(z.tolls_actual, z.tolls, 0) + z.maintenance + z.driver_pay) / (z.revenue / z.kg)) end as breakeven_kg
  from z;

create view public.rule_flags with (security_invoker = true) as
with s as (select * from public.settings where id = 1)
select 'R2'::text as rule, 'FLAG'::text as severity, 'GPS lost on a trip'::text as title,
       t.truck_no || ' last sent GPS ' || coalesce(round(extract(epoch from now() - t.last_ping_at) / 60) || ' min ago', 'never') as detail,
       t.truck_no as ref, t.last_ping_at as at
  from public.trucks t, s
 where exists (select 1 from public.orders o where o.truck_no = t.truck_no and o.status in ('driver_accepted','picked_up'))
   and not t.is_simulated
   and (t.last_ping_at is null or t.last_ping_at < now() - make_interval(mins => s.gps_fresh_minutes))
union all
select 'R2', 'FLAG', 'Impossible GPS jump', p.truck_no || ' moved faster than 120 km/h', p.truck_no, p.recorded_at
  from public.gps_pings p where p.flag = 'impossible_jump' and p.recorded_at > now() - interval '7 days'
union all
select 'R3', 'FLAG', 'Rejected scans', count(*) || ' wrong or unknown parcels scanned at ' || ps.warehouse || ' in 7 days', ps.warehouse, max(ps.scanned_at)
  from public.parcel_scans ps where ps.result in ('wrong_truck','not_found') and ps.scanned_at > now() - interval '7 days'
 group by ps.warehouse having count(*) >= 3
union all
select 'R5', 'FLAG', 'Long wait, no reason', v.truck_no || ' spent ' || v.total_min || ' min at ' || v.warehouse_name, v.warehouse, v.arrived_at
  from public.visit_times v where v.total_min >= 45 and v.delay_reason is null and v.last_scan_at is not null
union all
select 'R6', 'FLAG', 'Trip km estimated, not from GPS', p.truck_no || ' ' || p.origin_wh || '→' || coalesce(p.dest_wh, '?') || ': no GPS track for this trip', p.trip_key, p.assigned_at
  from public.trip_pnl p where p.completed and not p.km_from_gps
union all
select 'R6', 'STOP', 'No official toll data', 'Toll plazas are not imported yet: run tools/import_nhai_tolls.py', 'toll_plazas', now()
 where not exists (select 1 from public.toll_plazas)
union all
select 'R6', 'FLAG', 'Toll rate missing', p.truck_no || ': a plaza on this trip has no NHAI rate for class ' || p.toll_class, p.trip_key, p.assigned_at
  from public.trip_pnl p where p.toll_rate_missing
union all
select 'R8', 'FLAG', 'Trip losing money', p.truck_no || ' ' || p.origin_wh || '→' || coalesce(p.dest_wh, '?') || ': ₹' || p.profit || ' at ' || p.fill_pct || '% full', p.trip_key, p.assigned_at
  from public.trip_pnl p where p.profit < 0 and p.completed
union all
select 'R10', 'FLAG', 'Many manual changes', count(*) || ' manual status changes or early dispatches in 7 days', coalesce(e.by_user::text, 'unknown'), max(e.at)
  from public.order_events e
 where e.at > now() - interval '7 days' and (e.note like 'Changed in ops%' or e.note like '%Sent below fill target%')
 group by e.by_user having count(*) >= 5
union all
select 'R11', 'FLAG', 'Loading suspiciously fast', v.truck_no || ' at ' || v.warehouse_name || ': ' || v.parcels_scanned || ' parcels in ' || coalesce(v.loading_min, 0) || ' min', v.warehouse, v.first_scan_at
  from public.visit_times v
 where v.parcels_scanned >= 5 and v.last_scan_at is not null
   and extract(epoch from (v.last_scan_at - v.first_scan_at)) / v.parcels_scanned < 5
union all
select 'R12', 'STOP', 'Order without warehouse', o.awb || ' from pincode ' || o.pickup_pincode || ' has no origin warehouse', o.awb, o.created_at
  from public.orders o where o.status = 'booked' and o.origin_wh is null
union all
select 'R13', 'FLAG', 'Leg longer than limit', p.truck_no || ' ' || p.origin_wh || '→' || coalesce(p.dest_wh, '?') || ': ' || p.km_loaded || ' km loaded (limit ' || s.max_leg_km || ' km)', p.trip_key, p.assigned_at
  from public.trip_pnl p, s where p.km_from_gps and p.km_loaded > s.max_leg_km
union all
select 'R12', 'STOP', 'Order without route', o.awb || ': no warehouse for delivery pincode ' || o.delivery_pincode, o.awb, o.created_at
  from public.orders o where o.status = 'booked' and o.origin_wh is not null and o.dest_wh is null
union all
select 'R15', 'FLAG', 'Expressway toll not costed',
       p.truck_no || ' ' || p.origin_wh || '→' || coalesce(p.dest_wh, '?') || ': drove a closed-loop expressway (' || coalesce(p.expressway_nh, '?') || ')'
       || case when p.expressway_km_uncosted > 0 then ', ' || p.expressway_km_uncosted || ' km' else '' end
       || ' with no official per-km rate. Enter it in table expressway_rates.', p.trip_key, p.assigned_at
  from public.trip_pnl p where p.expressway_uncosted;

-- Every minute: expire unanswered offers, send ready trips (pg_cron; skipped if it is not available)
do $cron$
begin
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron is not available (%). Enable it in Database -> Extensions, then run this file again. Until then the ops page runs dispatch while it is open.', sqlerrm;
  end;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'dakbox-auto-dispatch';
    perform cron.schedule('dakbox-auto-dispatch', '* * * * *', 'select public.auto_dispatch()');
  end if;
end $cron$;

-- Permissions
revoke all on public.trip_pnl from anon;
revoke all on public.rule_flags from anon;
grant select on public.trip_pnl to authenticated;
grant select on public.rule_flags to authenticated;
revoke execute on function public.suggest_allocations(numeric,int) from public, anon;
grant execute on function public.suggest_allocations(numeric,int) to authenticated;
revoke execute on function public.driver_action(text,text) from public, anon, authenticated;
revoke execute on function public.lane_fit(text,text,numeric) from public, anon;
grant execute on function public.lane_fit(text,text,numeric) to authenticated;
revoke execute on function public.plan_return(text) from public, anon;
grant execute on function public.plan_return(text) to authenticated;
revoke execute on function public.offer_return_load(text,text[],timestamptz) from public, anon;
grant execute on function public.offer_return_load(text,text[],timestamptz) to authenticated;
revoke execute on function public.return_load_matches() from public, anon;
grant execute on function public.return_load_matches() to authenticated;
revoke execute on function public.auto_dispatch() from public, anon;
grant execute on function public.auto_dispatch() to authenticated;

-- check: how automatic dispatch runs
select case when to_regclass('cron.job') is null then 'Only while the ops page is open (enable pg_cron in Database -> Extensions, then run this file again)'
            else 'Every minute, in the database (pg_cron)' end as automatic_dispatch;
