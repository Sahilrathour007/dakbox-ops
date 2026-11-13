-- =====================================================================
-- Migration 007: hub-and-spoke network (no truck leg longer than 500 road km)
-- Run once in Supabase -> SQL Editor, AFTER migration_006 (safe to run again).
--
-- Why: a driver may work at most 8 hours a day and must rest after 5 hours
-- (Motor Transport Workers Act 1961, s.13 and s.15; Motor Vehicles Act 1988, s.91),
-- which at highway speeds is roughly 400-500 km. So parcels travel hub to hub:
--   * warehouses are hubs or spokes; a spoke connects only to its nearest hub;
--   * each parcel gets a route (shortest path, every hub-to-hub leg <= max_leg_km road km);
--   * dispatch, scanning, drivers and money all work leg by leg (one truck per leg);
--   * revenue is split across legs by distance; every leg is costed exactly as before
--     (GPS km incl. empty return, official NHAI tolls, IndianOil diesel, maintenance, driver).
-- =====================================================================

-- 1. Hubs and spokes, plus relay hubs on national-highway corridors (positions approximate: check them)
alter table public.warehouses add column if not exists is_hub boolean not null default true;
update public.warehouses set is_hub = false where code in ('DEL01','NOI01','BOM02','KNU01');
insert into public.warehouses (code, name, city, address, lat, lon, is_hub) values
 ('UDR01','Udaipur Relay Hub','Udaipur','Relay hub, NH 48 corridor (approximate position)',24.5854,73.7125,true),
 ('STV01','Surat Relay Hub','Surat','Relay hub, NH 48 corridor (approximate position)',21.1702,72.8311,true),
 ('IDR01','Indore Relay Hub','Indore','Relay hub, NH 52 corridor (approximate position)',22.7196,75.8577,true),
 ('NAG01','Nagpur Relay Hub','Nagpur','Relay hub, NH 44 corridor (approximate position)',21.1458,79.0882,true),
 ('AGR01','Agra Relay Hub','Agra','Relay hub, NH 19 / NH 44 corridor (approximate position)',27.1767,78.0081,true),
 ('VNS01','Varanasi Relay Hub','Varanasi','Relay hub, NH 19 corridor (approximate position)',25.3176,82.9739,true),
 ('GAY01','Gaya Relay Hub','Gaya','Relay hub, NH 19 corridor (approximate position)',24.7914,85.0002,true),
 ('DHN01','Dhanbad Relay Hub','Dhanbad','Relay hub, NH 19 corridor (approximate position)',23.7957,86.4304,true),
 ('VGA01','Vijayawada Relay Hub','Vijayawada','Relay hub, NH 16 corridor (approximate position)',16.5062,80.6480,true),
 ('NLR01','Nellore Relay Hub','Nellore','Relay hub, NH 16 corridor (approximate position)',14.4426,79.9865,true),
 ('SSE01','Solapur Relay Hub','Solapur','Relay hub, NH 65 corridor (approximate position)',17.6599,75.9064,true),
 ('KNL01','Kurnool Relay Hub','Kurnool','Relay hub, NH 44 corridor (approximate position)',15.8281,78.0373,true),
 ('HBL01','Hubballi Relay Hub','Hubballi','Relay hub, NH 48 corridor (approximate position)',15.3647,75.1240,true),
 ('CTA01','Chitradurga Relay Hub','Chitradurga','Relay hub, NH 48 corridor (approximate position)',14.2251,76.3980,true),
 ('RPR01','Raipur Relay Hub','Raipur','Relay hub, NH 53 corridor (approximate position)',21.2514,81.6296,true),
 ('BBI01','Bhubaneswar Relay Hub','Bhubaneswar','Relay hub, NH 16 corridor (approximate position)',20.2961,85.8245,true)
on conflict (code) do nothing;

alter table public.settings add column if not exists max_leg_km numeric not null default 500;
alter table public.settings add column if not exists hub_sort_minutes int not null default 30;

-- 2. Route planner: shortest path where a spoke links only to its nearest hub and
--    hub-to-hub links are at most max_leg_km road km (straight km x road_factor).
create or replace function public.plan_route(p_from text, p_to text)
returns text[] language plpgsql stable set search_path = public as $$
declare s record; codes text[]; lats double precision[]; lons double precision[]; hub boolean[];
        n int; dist double precision[]; prev int[]; done boolean[]; nh int[];
        i int; j int; u int; a int; b int; best double precision; w double precision; path text[];
begin
  if p_from is null or p_to is null then return null; end if;
  if p_from = p_to then return array[p_from]; end if;
  select * into s from public.settings where id = 1;
  select array_agg(code order by code), array_agg(lat order by code), array_agg(lon order by code), array_agg(is_hub order by code)
    into codes, lats, lons, hub from public.warehouses where active;
  n := coalesce(array_length(codes, 1), 0);
  a := array_position(codes, p_from); b := array_position(codes, p_to);
  if a is null or b is null then return null; end if;
  nh := array_fill(0, array[n]);
  for i in 1..n loop
    if not hub[i] then
      best := 1e18;
      for j in 1..n loop
        if hub[j] then w := public.km(lats[i], lons[i], lats[j], lons[j]); if w < best then best := w; nh[i] := j; end if; end if;
      end loop;
    end if;
  end loop;
  dist := array_fill(1e18::double precision, array[n]); prev := array_fill(0, array[n]); done := array_fill(false, array[n]);
  dist[a] := 0;
  loop
    u := 0; best := 1e18;
    for i in 1..n loop if not done[i] and dist[i] < best then best := dist[i]; u := i; end if; end loop;
    exit when u = 0 or u = b;
    done[u] := true;
    for j in 1..n loop
      continue when done[j] or j = u;
      if (not hub[u] and nh[u] = j) or (not hub[j] and nh[j] = u) or (hub[u] and hub[j]) then
        w := public.km(lats[u], lons[u], lats[j], lons[j]) * s.road_factor;
        continue when hub[u] and hub[j] and w > s.max_leg_km;
        if dist[u] + w < dist[j] then dist[j] := dist[u] + w; prev[j] := u; end if;
      end if;
    end loop;
  end loop;
  if dist[b] >= 1e18 then return null; end if;
  path := array[codes[b]]; i := b;
  while i <> a loop i := prev[i]; path := codes[i] || path; end loop;
  return path;
end $$;

-- 3. Orders follow their route leg by leg
alter table public.orders add column if not exists route   text[];   -- warehouse codes, origin first
alter table public.orders add column if not exists leg_no  int not null default 1;
alter table public.orders add column if not exists cur_wh  text references public.warehouses(code);  -- where the parcel is now / loads
alter table public.orders add column if not exists next_wh text references public.warehouses(code);  -- where the current leg ends
create index if not exists orders_leg_idx on public.orders (cur_wh, next_wh, status);

create or replace function public.set_order_warehouses()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.origin_wh is null then
    new.origin_wh := coalesce(public.nearest_warehouse(new.pickup_lat, new.pickup_lon), public.warehouse_for_pincode(new.pickup_pincode));
  end if;
  if new.dest_wh is null then new.dest_wh := public.warehouse_for_pincode(new.delivery_pincode); end if;
  if new.route is null and new.origin_wh is not null and new.dest_wh is not null then
    new.route := coalesce(public.plan_route(new.origin_wh, new.dest_wh), array[new.origin_wh, new.dest_wh]);
  end if;
  new.cur_wh := coalesce(new.cur_wh, new.origin_wh);
  if new.next_wh is null and new.route is not null and array_length(new.route, 1) >= 2 then new.next_wh := new.route[2]; end if;
  return new;
end $$;

-- existing parcels: waiting ones get a route; ones already on a truck keep their direct trip as one leg
update public.orders set route = coalesce(public.plan_route(origin_wh, dest_wh), array[origin_wh, dest_wh]),
       cur_wh = origin_wh, leg_no = 1
 where route is null and origin_wh is not null and dest_wh is not null and status = 'booked' and truck_no is null;
update public.orders set next_wh = route[2] where next_wh is null and route is not null and array_length(route, 1) >= 2 and status = 'booked';
update public.orders set route = array[origin_wh, dest_wh], cur_wh = origin_wh, next_wh = dest_wh, leg_no = 1
 where route is null and origin_wh is not null and dest_wh is not null;

-- 4. Each leg a parcel rides: the record dispatch, scans, drivers and money use
create table if not exists public.parcel_legs (
  id            bigserial primary key,
  awb           text not null references public.orders(awb) on delete cascade,
  leg_no        int not null,
  from_wh       text not null references public.warehouses(code),
  to_wh         text not null references public.warehouses(code),
  truck_no      text references public.trucks(truck_no) on delete cascade,
  assigned_at   timestamptz not null,
  loaded_at     timestamptz,
  unloaded_at   timestamptz,
  to_wh_km      numeric,           -- truck's distance to the leg's start warehouse when dispatched
  driver_pay    numeric,
  revenue_share numeric not null   -- this leg's slice of the truck revenue (split by distance)
);
create index if not exists parcel_legs_trip_idx on public.parcel_legs (truck_no, from_wh, to_wh, assigned_at);
create index if not exists parcel_legs_awb_idx on public.parcel_legs (awb, leg_no);
alter table public.parcel_legs enable row level security;
drop policy if exists staff_read on public.parcel_legs;
create policy staff_read on public.parcel_legs for select to authenticated using (true);

-- revenue slice for one leg of an order: freight x line-haul share x leg km / route km
create or replace function public.leg_revenue(p_awb text, p_from text, p_to text)
returns numeric language sql stable set search_path = public as $$
  with o as (select * from public.orders where awb = p_awb),
       pts as (select r.ord, w.lat, w.lon from o, unnest(o.route) with ordinality r(code, ord) join public.warehouses w on w.code = r.code),
       tot as (select coalesce(sum(public.km(a.lat, a.lon, b.lat, b.lon)), 0) as km from pts a join pts b on b.ord = a.ord + 1),
       leg as (select public.km(a.lat, a.lon, b.lat, b.lon) as km from public.warehouses a, public.warehouses b where a.code = p_from and b.code = p_to)
  select round((o.freight * s.line_haul_share * case when tot.km > 0 then leg.km / tot.km else 1 end)::numeric, 2)
    from o, tot, leg, public.settings s where s.id = 1
$$;

-- legs for parcels that were already on a truck before this update (history stays in the money view)
insert into public.parcel_legs (awb, leg_no, from_wh, to_wh, truck_no, assigned_at, loaded_at, unloaded_at, to_wh_km, driver_pay, revenue_share)
select o.awb, 1, o.origin_wh, o.dest_wh, o.truck_no, o.assigned_at,
       (select min(at) from public.order_events e where e.awb = o.awb and e.status = 'picked_up'),
       (select min(at) from public.order_events e where e.awb = o.awb and e.status = 'at_destination_hub'),
       o.pickup_distance_km, o.driver_pay, round(o.freight * (select line_haul_share from public.settings where id = 1), 2)
  from public.orders o
 where o.truck_no is not null and o.assigned_at is not null and o.origin_wh is not null and o.dest_wh is not null
   and not exists (select 1 from public.parcel_legs l where l.awb = o.awb);

-- 5. Parcels still to scan for a truck at a warehouse (now per leg)
create or replace function public.parcels_remaining(p_truck text, p_wh text, p_purpose text)
returns int language sql stable set search_path = public as $$
  select count(*)::int from public.orders o where o.truck_no = p_truck and
    case when p_purpose = 'load'
         then o.cur_wh  = p_wh and o.status in ('pickup_assigned','driver_accepted')
         else o.next_wh = p_wh and o.status = 'picked_up' end
$$;

-- 6. Dispatch per leg
create or replace function public.suggest_allocations(p_max_km numeric default null, p_fresh_min int default null)
returns table (awb text, truck_no text, distance_km numeric, reason text)
language plpgsql stable security definer set search_path = public as $$
declare
  s record; o record; best record; near record; maxkm numeric; freshmin int;
  used_kg jsonb := '{}'::jsonb;      -- truck -> kg added in this run
  lane_of jsonb := '{}'::jsonb;      -- truck -> route it took in this run
  lane text; t text; fk numeric;
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
       order by 2 limit 1;
    end if;

    if best.tno is not null then
      truck_no := best.tno; distance_km := round(best.d::numeric, 1);
      fk := coalesce((used_kg ->> best.tno)::numeric, 0) + o.charged_kg;
      used_kg := used_kg || jsonb_build_object(best.tno, fk);
      lane_of := lane_of || jsonb_build_object(best.tno, lane);
      reason := case when t is not null then 'Joins the same truck on this route'
                     else 'Nearest free truck to ' || o.wname end;
      t := null; best := null;
      return next; continue;
    end if;
    t := null;

    -- explain why nothing fits, using the nearest truck to the warehouse
    select tr.truck_no as tno, public.km(o.wlat, o.wlon, tr.last_lat, tr.last_lon) as d,
           tr.status, tr.last_ping_at, tr.capacity_kg - tr.load_kg - coalesce((used_kg ->> tr.truck_no)::numeric, 0) as free,
           exists (select 1 from public.orders a where a.truck_no = tr.truck_no
                    and a.status in ('pickup_assigned','driver_accepted','picked_up')) as busy
      into near from public.trucks tr where tr.last_lat is not null
     order by public.km(o.wlat, o.wlon, tr.last_lat, tr.last_lon) limit 1;
    reason := case
      when near.tno is null then 'No truck has sent GPS yet'
      when near.d > maxkm then 'Nearest truck ' || near.tno || ' is ' || round(near.d::numeric) || ' km from ' || o.wname || ' (limit ' || maxkm || ' km)'
      when near.status <> 'available' then 'Nearest truck ' || near.tno || ' is ' || replace(near.status, '_', ' ')
      when near.last_ping_at < now() - make_interval(mins => freshmin) then 'Nearest truck ' || near.tno || ': GPS last seen ' || round(extract(epoch from now() - near.last_ping_at) / 60) || ' min ago'
      when near.busy or lane_of ? near.tno then 'Nearest truck ' || near.tno || ' is already on another trip'
      else 'Nearest truck ' || near.tno || ' has only ' || round(near.free) || ' kg free' end;
    return next;
  end loop;
end $$;

create or replace function public.confirm_allocations(p_max_km numeric default null, p_fresh_min int default null,
                                                      p_send_now text[] default null, p_reason text default null)
returns int language plpgsql security definer set search_path = public as $$
declare r record; g record; n int := 0; s record; done text[] := '{}'; v_send text[]; forced_early boolean;
begin
  perform pg_advisory_xact_lock(4242);
  select * into s from public.settings where id = 1;

  select coalesce(array_agg(q.awb) filter (where q.ready or q.forced), '{}'),
         coalesce(bool_or(q.forced and not q.ready), false)
    into v_send, forced_early
    from (select sg.awb,
                 (sum(o.charged_kg) over w) / tr.capacity_kg * 100 >= s.min_fill_pct
                   or (min(o.created_at) over w) <= now() - make_interval(hours => s.max_wait_hours::int) as ready,
                 bool_or(sg.awb = any(coalesce(p_send_now, '{}'))) over w as forced
            from public.suggest_allocations(p_max_km, p_fresh_min) sg
            join public.orders o on o.awb = sg.awb
            join public.trucks tr on tr.truck_no = sg.truck_no
           where sg.truck_no is not null
          window w as (partition by sg.truck_no, o.cur_wh, o.next_wh)) q;

  if forced_early and length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception 'Give a reason for sending a truck below its fill target';
  end if;

  for r in select * from public.suggest_allocations(p_max_km, p_fresh_min) where truck_no is not null and awb = any(v_send) loop
    update public.orders o set truck_no = r.truck_no, status = 'pickup_assigned', assigned_at = now(),
           pickup_distance_km = r.distance_km
     where o.awb = r.awb and o.status in ('booked','in_transit') and o.truck_no is null;
    if found then
      insert into public.parcel_legs (awb, leg_no, from_wh, to_wh, truck_no, assigned_at, to_wh_km, revenue_share)
      select o.awb, o.leg_no, o.cur_wh, o.next_wh, r.truck_no, now(), r.distance_km, public.leg_revenue(o.awb, o.cur_wh, o.next_wh)
        from public.orders o where o.awb = r.awb;
      update public.trucks t set load_kg = t.load_kg + (select charged_kg from public.orders where awb = r.awb)
       where t.truck_no = r.truck_no;
      insert into public.order_events (awb, status, truck_no, note, by_user)
      values (r.awb, 'pickup_assigned', r.truck_no,
              'Truck ' || r.distance_km || ' km from warehouse'
              || case when r.awb = any(coalesce(p_send_now, '{}')) and forced_early then '. Sent below fill target: ' || trim(p_reason) else '' end,
              auth.uid());
      done := done || r.awb; n := n + 1;
    end if;
  end loop;

  for g in
    select o.truck_no, o.cur_wh, o.next_wh, count(*) as parcels, max(o.pickup_distance_km) as to_wh_km,
           coalesce(public.km(wo.lat, wo.lon, wd.lat, wd.lon), 0) as trip_km
      from public.orders o
      join public.warehouses wo on wo.code = o.cur_wh
      left join public.warehouses wd on wd.code = o.next_wh
     where o.awb = any(done)
     group by o.truck_no, o.cur_wh, o.next_wh, wo.lat, wo.lon, wd.lat, wd.lon
  loop
    update public.orders set driver_pay = round((s.trip_pay_base + s.trip_pay_per_km * (g.to_wh_km + g.trip_km)) / g.parcels)
     where awb = any(done) and truck_no = g.truck_no and cur_wh = g.cur_wh and coalesce(next_wh,'') = coalesce(g.next_wh,'');
  end loop;
  update public.parcel_legs l set driver_pay = o.driver_pay from public.orders o
   where o.awb = l.awb and l.awb = any(done) and l.leg_no = o.leg_no and l.truck_no = o.truck_no;
  return n;
end $$;

-- 7. Scanning per leg
create or replace function public.scan_parcel_at(p_wh text, p_truck text, p_awb text, p_mode text, p_at timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.orders; v public.warehouse_visits; v_awb text := regexp_replace(coalesce(p_awb,''), '\D', '', 'g');
        remaining int; msg text;
begin
  if p_mode not in ('load','unload') then raise exception 'Mode must be load or unload'; end if;
  select * into o from public.orders where orders.awb = v_awb for update;

  -- open visit for this truck at this warehouse (created by GPS arrival, or now)
  select * into v from public.warehouse_visits wv
   where wv.truck_no = p_truck and wv.warehouse = p_wh and wv.purpose = p_mode and wv.departed_at is null
   order by wv.id desc limit 1;

  if o.awb is null then
    insert into public.parcel_scans (visit_id, awb, warehouse, truck_no, scan_type, result, by_user, scanned_at)
    values (v.id, coalesce(nullif(v_awb,''), p_awb), p_wh, p_truck, p_mode, 'not_found', auth.uid(), p_at);
    return jsonb_build_object('result','not_found','message','No parcel with AWB ' || coalesce(nullif(v_awb,''), p_awb));
  end if;

  if v.id is not null and exists (select 1 from public.parcel_scans s where s.visit_id = v.id and s.awb = o.awb and s.result = 'ok') then
    insert into public.parcel_scans (visit_id, awb, warehouse, truck_no, scan_type, result, by_user, scanned_at)
    values (v.id, o.awb, p_wh, p_truck, p_mode, 'duplicate', auth.uid(), p_at);
    return jsonb_build_object('result','duplicate','message','Already scanned','scanned',v.parcels_scanned,'expected',v.parcels_expected);
  end if;

  if o.truck_no is distinct from p_truck
     or (p_mode = 'load'   and (o.cur_wh <> p_wh or o.status not in ('pickup_assigned','driver_accepted')))
     or (p_mode = 'unload' and (o.next_wh  <> p_wh or o.status <> 'picked_up')) then
    msg := case when o.truck_no is null then 'This parcel has no truck yet'
                when o.truck_no <> p_truck then 'Wrong truck: this parcel goes on ' || o.truck_no
                when p_mode = 'load' and o.cur_wh <> p_wh then 'Wrong warehouse: this parcel loads at ' || o.cur_wh
                when p_mode = 'unload' and o.next_wh <> p_wh then 'Wrong warehouse: this parcel unloads at ' || coalesce(o.next_wh, '?')
                else 'Not ready for this step (status: ' || replace(o.status,'_',' ') || ')' end;
    insert into public.parcel_scans (visit_id, awb, warehouse, truck_no, scan_type, result, by_user, scanned_at)
    values (v.id, o.awb, p_wh, p_truck, p_mode, 'wrong_truck', auth.uid(), p_at);
    return jsonb_build_object('result','wrong_truck','message',msg);
  end if;

  if v.id is null then
    insert into public.warehouse_visits (truck_no, warehouse, purpose, arrived_at, arrival_source)
    values (p_truck, p_wh, p_mode, p_at, 'scan') returning * into v;
  end if;

  insert into public.parcel_scans (visit_id, awb, warehouse, truck_no, scan_type, result, by_user, scanned_at)
  values (v.id, o.awb, p_wh, p_truck, p_mode, 'ok', auth.uid(), p_at);

  if p_mode = 'load' then
    update public.orders set status = 'picked_up', accepted_at = coalesce(accepted_at, p_at) where orders.awb = o.awb;
    update public.parcel_legs set loaded_at = p_at where awb = o.awb and leg_no = o.leg_no and truck_no = p_truck and loaded_at is null;
    insert into public.order_events (awb, status, truck_no, note, by_user, at) values (o.awb, 'picked_up', p_truck, 'Loaded at ' || p_wh, auth.uid(), p_at);
  else
    update public.trucks tr set load_kg = greatest(0, tr.load_kg - o.charged_kg) where tr.truck_no = p_truck;
    update public.parcel_legs set unloaded_at = p_at where awb = o.awb and leg_no = o.leg_no and truck_no = p_truck and unloaded_at is null;
    if o.next_wh = o.dest_wh then
      update public.orders set status = 'at_destination_hub', cur_wh = o.next_wh where orders.awb = o.awb;
      insert into public.order_events (awb, status, truck_no, note, by_user, at) values (o.awb, 'at_destination_hub', p_truck, 'Unloaded at ' || p_wh, auth.uid(), p_at);
    else
      -- middle hub: the parcel waits here for the truck of its next leg
      update public.orders set status = 'in_transit', truck_no = null, cur_wh = o.next_wh, leg_no = o.leg_no + 1,
             next_wh = o.route[o.leg_no + 2], assigned_at = null, accepted_at = null, driver_pay = null, pickup_distance_km = null
       where orders.awb = o.awb;
      insert into public.order_events (awb, status, truck_no, note, by_user, at) values (o.awb, 'in_transit', p_truck, 'At hub ' || p_wh || ', waiting for the next truck', auth.uid(), p_at);
    end if;
  end if;

  remaining := public.parcels_remaining(p_truck, p_wh, p_mode);
  update public.warehouse_visits wv set
     first_scan_at = coalesce(wv.first_scan_at, p_at), last_scan_at = p_at,
     parcels_scanned = wv.parcels_scanned + 1, parcels_expected = wv.parcels_scanned + 1 + remaining
   where wv.id = v.id returning * into v;

  return jsonb_build_object('result','ok','message','Scanned ' || o.awb,'scanned',v.parcels_scanned,
                            'expected',v.parcels_expected,'done',remaining = 0,'visit_id',v.id);
end $$;

create or replace function public.driver_trip_action(p_truck text, p_origin text, p_dest text, p_action text)
returns int language plpgsql security definer set search_path = public as $$
declare a text; n int := 0; from_status text[];
begin
  from_status := case p_action when 'accept' then array['pickup_assigned']
                               when 'decline' then array['pickup_assigned','driver_accepted'] end;
  if from_status is null then raise exception 'Loading and unloading are recorded by the warehouse scan'; end if;
  for a in select awb from public.orders where truck_no = p_truck and cur_wh = p_origin
             and coalesce(next_wh,'') = coalesce(p_dest,'') and status = any(from_status) loop
    perform public.driver_action(a, p_action); n := n + 1;
  end loop;
  if n = 0 then raise exception 'This trip has already moved on. Pull down to refresh.'; end if;
  return n;
end $$;

-- 8. Driver: accept or decline the current leg (loading and unloading are recorded by scans)
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

-- 9. Simulation: give waiting parcels on one leg to a simulated truck
create or replace function public.sim_assign(p_truck text, p_awbs text[], p_at timestamptz, p_to_wh_km numeric)
returns int language plpgsql security definer set search_path = public as $$
declare s record; n int; trip_km numeric; o1 record;
begin
  if not exists (select 1 from public.trucks where truck_no = p_truck and is_simulated) then
    raise exception 'Only simulated trucks can be assigned here'; end if;
  if p_at > now() then raise exception 'Simulated time cannot be in the future'; end if;
  select * into s from public.settings where id = 1;
  update public.orders set truck_no = p_truck, status = 'driver_accepted', assigned_at = p_at, accepted_at = p_at,
         pickup_distance_km = round(p_to_wh_km, 1)
   where awb = any(p_awbs) and status in ('booked','in_transit') and truck_no is null and next_wh is not null;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'None of these parcels is waiting for a truck'; end if;
  select o.cur_wh, o.next_wh into o1 from public.orders o where o.awb = any(p_awbs) and o.truck_no = p_truck limit 1;
  select coalesce(public.km(a.lat, a.lon, b.lat, b.lon), 0) into trip_km
    from public.warehouses a, public.warehouses b where a.code = o1.cur_wh and b.code = o1.next_wh;
  update public.orders set driver_pay = round((s.trip_pay_base + s.trip_pay_per_km * (p_to_wh_km + coalesce(trip_km, 0))) / n)
   where awb = any(p_awbs) and truck_no = p_truck;
  insert into public.parcel_legs (awb, leg_no, from_wh, to_wh, truck_no, assigned_at, to_wh_km, driver_pay, revenue_share)
  select awb, leg_no, cur_wh, next_wh, p_truck, p_at, round(p_to_wh_km, 1), driver_pay, public.leg_revenue(awb, cur_wh, next_wh)
    from public.orders where awb = any(p_awbs) and truck_no = p_truck;
  update public.trucks t set load_kg = t.load_kg + (select coalesce(sum(charged_kg), 0) from public.orders where awb = any(p_awbs) and truck_no = p_truck)
   where t.truck_no = p_truck;
  insert into public.order_events (awb, status, truck_no, note, by_user, at)
  select awb, 'driver_accepted', p_truck, 'Simulation, leg ' || leg_no, auth.uid(), p_at from public.orders where awb = any(p_awbs) and truck_no = p_truck;
  return n;
end $$;

-- 10. Tracking shows the route and where the parcel is now (names only)
create or replace function public.track_order(p_awb text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'awb', o.awb, 'status', o.status, 'service', o.service,
    'from_pincode', o.pickup_pincode, 'to_pincode', o.delivery_pincode,
    'from_warehouse', wo.name, 'to_warehouse', wd.name, 'now_at', wc.name,
    'route', (select jsonb_agg(w.name order by r.ord) from unnest(o.route) with ordinality r(code, ord) join public.warehouses w on w.code = r.code),
    'leg_no', o.leg_no, 'legs', coalesce(array_length(o.route, 1) - 1, 1),
    'charged_kg', o.charged_kg, 'pickup_date', o.pickup_date, 'eta_date', o.eta_date,
    'events', coalesce((select jsonb_agg(jsonb_build_object('status', e.status, 'at', e.at) order by e.at)
                        from public.order_events e where e.awb = o.awb), '[]'::jsonb))
  from public.orders o
  left join public.warehouses wo on wo.code = o.origin_wh
  left join public.warehouses wd on wd.code = o.dest_wh
  left join public.warehouses wc on wc.code = o.cur_wh
  where o.awb = regexp_replace(p_awb, '\s', '', 'g')
$$;

-- 11. Money per leg trip (same cost formulas as migration 006)
drop view if exists public.rule_flags;
drop view if exists public.trip_pnl;
create view public.trip_pnl with (security_invoker = true) as
with s as (select * from public.settings where id = 1),
t as (
  select l.truck_no, l.from_wh as origin_wh, l.to_wh as dest_wh, l.assigned_at,
         l.truck_no || '|' || l.from_wh || '|' || l.to_wh || '|' || floor(extract(epoch from l.assigned_at))::bigint as trip_key,
         count(*)::int as parcels, sum(o.charged_kg) as kg, sum(l.revenue_share) as revenue_legs,
         coalesce(sum(l.driver_pay), 0) as driver_pay, coalesce(max(l.to_wh_km), 0) as to_wh_km,
         bool_and(l.unloaded_at is not null) as completed
    from public.parcel_legs l join public.orders o on o.awb = l.awb
   where l.truck_no is not null
   group by l.truck_no, l.from_wh, l.to_wh, l.assigned_at),
x as (
  select t.*, wo.name as from_name, wd.name as to_name, tr.capacity_kg, tr.toll_class,
         coalesce(public.km(wo.lat, wo.lon, wd.lat, wd.lon), 0) as straight_km,
         lv.total_min as load_dwell_min, lv.last_scan_at as loaded_at,
         uv.total_min as unload_dwell_min, uv.last_scan_at as unloaded_at,
         ret.at as returned_at,
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
    left join public.trip_costs c on c.trip_key = t.trip_key),
g as (
  select x.*, coalesce(x.returned_at, now()) as window_end,
         gp.total_km, gp.loaded_km, gp.moving_km, gp.moving_h,
         te.tolls, te.toll_count, te.missing_rates
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
      select sum(e.amount) as tolls, count(*)::int as toll_count, bool_or(e.rate_missing) as missing_rates
        from public.toll_events e
       where e.truck_no = x.truck_no and e.at >= x.assigned_at and e.at <= coalesce(x.returned_at, now())) te on true),
y as (
  select g.*,
         -- km: from GPS when the truck sent positions, otherwise an estimate
         (coalesce(g.total_km, 0) > 0) as km_from_gps,
         case when coalesce(g.total_km, 0) > 0 then g.total_km
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
select z.trip_key, z.truck_no, z.toll_class, z.origin_wh, z.dest_wh, z.from_name, z.to_name, z.assigned_at,
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
  from public.orders o where o.status = 'booked' and o.origin_wh is not null and o.dest_wh is null;

-- 12. Permissions
revoke all on public.trip_pnl from anon;
revoke all on public.rule_flags from anon;
revoke all on public.parcel_legs from anon;
grant select on public.trip_pnl to authenticated;
grant select on public.rule_flags to authenticated;
revoke execute on function public.plan_route(text,text) from public, anon;
revoke execute on function public.leg_revenue(text,text,text) from public, anon;
revoke execute on function public.parcels_remaining(text,text,text) from public, anon;
revoke execute on function public.suggest_allocations(numeric,int) from public, anon;
revoke execute on function public.confirm_allocations(numeric,int,text[],text) from public, anon;
revoke execute on function public.scan_parcel_at(text,text,text,text,timestamptz) from public, anon, authenticated;
revoke execute on function public.driver_action(text,text) from public, anon, authenticated;
revoke execute on function public.driver_trip_action(text,text,text,text) from public, anon;
revoke execute on function public.sim_assign(text,text[],timestamptz,numeric) from public, anon;
revoke execute on function public.set_order_warehouses() from public, anon, authenticated;
grant execute on function public.plan_route(text,text) to authenticated;
grant execute on function public.leg_revenue(text,text,text) to authenticated;
grant execute on function public.parcels_remaining(text,text,text) to authenticated;
grant execute on function public.suggest_allocations(numeric,int) to authenticated;
grant execute on function public.confirm_allocations(numeric,int,text[],text) to authenticated;
grant execute on function public.driver_trip_action(text,text,text,text) to authenticated;
grant execute on function public.sim_assign(text,text[],timestamptz,numeric) to authenticated;
grant execute on function public.track_order(text) to anon, authenticated;
