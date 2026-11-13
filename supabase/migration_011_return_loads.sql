-- =====================================================================
-- Migration 011: return loads (backhaul)
-- Run once in Supabase -> SQL Editor, AFTER migration_010 (safe to run again).
--
-- A truck that has unloaded drives home anyway. Parcels waiting at that warehouse whose next
-- leg goes to the truck's home warehouse can ride along:
--   * when the last parcel is scanned off, the system offers them to the driver automatically;
--   * ops see every truck's return trip and its waiting parcels on the Return loads tab;
--   * money: a trip now ends when the truck starts its next job, so the drive home is counted
--     once - on the return load if there is one, otherwise on the trip itself (as before).
-- =====================================================================

alter table public.parcel_legs add column if not exists backhaul boolean not null default false;

-- Offer waiting parcels for the drive home to a truck (oldest first, as many as fit).
-- p_awbs = null: every waiting parcel that fits. p_at: when (the unload time when offered by a scan).
-- Returns how many parcels were offered.
drop function if exists public.offer_return_load(text,text[]);
create or replace function public.offer_return_load(p_truck text, p_awbs text[] default null, p_at timestamptz default now())
returns int language plpgsql security definer set search_path = public as $$
declare s record; tr public.trucks; lg record; n int; km_ab numeric; free numeric; picked text[];
begin
  select * into s from public.settings where id = 1;
  select * into tr from public.trucks where truck_no = p_truck for update;
  if tr.truck_no is null then raise exception 'No truck %', p_truck; end if;
  -- the truck's latest outward trip; its start is home, its end is where the return load waits
  select l.from_wh, l.to_wh, l.assigned_at into lg from public.parcel_legs l
   where l.truck_no = p_truck and not l.backhaul order by l.assigned_at desc limit 1;
  if lg.from_wh is null then return 0; end if;
  if exists (select 1 from public.parcel_legs l where l.truck_no = p_truck and l.backhaul and l.assigned_at > lg.assigned_at) then
    return 0;   -- already has a return load
  end if;
  free := tr.capacity_kg - coalesce((select sum(o.charged_kg) from public.orders o
            where o.truck_no = p_truck and o.status in ('pickup_assigned','driver_accepted','picked_up') and o.next_wh <> lg.to_wh), 0);
  select array_agg(awb order by created_at) into picked from (
    select o.awb, o.created_at, sum(o.charged_kg) over (order by o.created_at, o.awb) as run_kg
      from public.orders o
     where o.cur_wh = lg.to_wh and o.next_wh = lg.from_wh and o.status in ('booked','in_transit') and o.truck_no is null
       and (p_awbs is null or o.awb = any(p_awbs))) q
   where run_kg <= free;
  n := coalesce(array_length(picked, 1), 0);
  if n = 0 then return 0; end if;
  select coalesce(public.km(a.lat, a.lon, b.lat, b.lon), 0) into km_ab from public.warehouses a, public.warehouses b
   where a.code = lg.from_wh and b.code = lg.to_wh;
  update public.orders set truck_no = p_truck, status = 'pickup_assigned', assigned_at = p_at, accepted_at = null,
         pickup_distance_km = 0, driver_pay = round((s.trip_pay_base + s.trip_pay_per_km * km_ab) / n)
   where awb = any(picked);
  insert into public.parcel_legs (awb, leg_no, from_wh, to_wh, truck_no, assigned_at, to_wh_km, driver_pay, revenue_share, backhaul)
  select o.awb, o.leg_no, o.cur_wh, o.next_wh, p_truck, o.assigned_at, 0, o.driver_pay, public.leg_revenue(o.awb, o.cur_wh, o.next_wh), true
    from public.orders o where o.awb = any(picked);
  update public.trucks t set load_kg = t.load_kg + (select sum(charged_kg) from public.orders where awb = any(picked))
   where t.truck_no = p_truck;
  insert into public.order_events (awb, status, truck_no, note, by_user, at)
  select awb, 'pickup_assigned', p_truck, 'Return load offered to ' || p_truck, auth.uid(), p_at from public.orders where awb = any(picked);
  return n;
end $$;

-- Every real truck between its outward trip and home: the return trip and what could ride on it.
-- extra_cost = what carrying the load home adds (diesel loaded instead of empty, driver trip pay);
-- own_truck_cost = sending the same parcels on a separate truck (there and back; tolls not included).
create or replace function public.return_load_matches()
returns table (truck_no text, driver_name text, driver_phone text, stage text, at_wh text, home_wh text,
               at_name text, home_name text, free_kg numeric, waiting_parcels int, waiting_kg numeric,
               fit_parcels int, fit_kg numeric, revenue numeric, extra_cost numeric, own_truck_cost numeric,
               offered int, accepted int, last_ping_at timestamptz)
language sql stable set search_path = public as $$
  with s as (select * from public.settings where id = 1),
  trip as (
    select l.truck_no, l.from_wh, l.to_wh, l.assigned_at, bool_or(l.loaded_at is not null) as loaded,
           bool_and(l.unloaded_at is not null) as unloaded, max(l.unloaded_at) as unloaded_at
      from public.parcel_legs l where not l.backhaul group by 1, 2, 3, 4),
  last_trip as (
    select distinct on (t.truck_no) t.* from trip t join public.trucks tr on tr.truck_no = t.truck_no and not tr.is_simulated
     order by t.truck_no, t.assigned_at desc),
  cur as (
    select lt.*, tr.driver_name, tr.driver_phone, tr.capacity_kg, tr.last_ping_at, a.name as home_name, b.name as at_name,
           public.km(a.lat, a.lon, b.lat, b.lon) as km_ab,
           (select count(*) from public.parcel_legs l join public.orders o on o.awb = l.awb
             where l.truck_no = lt.truck_no and l.backhaul and l.assigned_at > lt.assigned_at and o.status = 'pickup_assigned')::int as offered,
           (select count(*) from public.parcel_legs l
             where l.truck_no = lt.truck_no and l.backhaul and l.assigned_at > lt.assigned_at and l.loaded_at is null) as open_backhaul,
           (select count(*) from public.parcel_legs l join public.orders o on o.awb = l.awb
             where l.truck_no = lt.truck_no and l.backhaul and l.assigned_at > lt.assigned_at and o.status in ('driver_accepted','picked_up'))::int as accepted,
           (select coalesce(sum(o.charged_kg), 0) from public.parcel_legs l join public.orders o on o.awb = l.awb
             where l.truck_no = lt.truck_no and l.backhaul and l.assigned_at > lt.assigned_at) as backhaul_kg
      from last_trip lt
      join public.trucks tr on tr.truck_no = lt.truck_no
      join public.warehouses a on a.code = lt.from_wh
      join public.warehouses b on b.code = lt.to_wh
     where (not lt.unloaded or lt.unloaded_at > now() - interval '24 hours')
       -- not back home yet
       and not exists (select 1 from public.gps_pings p where p.truck_no = lt.truck_no and lt.unloaded_at is not null
                         and p.recorded_at > lt.unloaded_at and public.km(p.lat, p.lon, a.lat, a.lon) <= 0.5)),
  w as (
    select c.truck_no, o.awb, o.charged_kg,
           sum(o.charged_kg) over (partition by c.truck_no order by o.created_at, o.awb) as run_kg,
           c.capacity_kg - c.backhaul_kg as free
      from cur c join public.orders o on o.cur_wh = c.to_wh and o.next_wh = c.from_wh
     where o.status in ('booked','in_transit') and o.truck_no is null)
  select c.truck_no, c.driver_name, c.driver_phone,
         case when not c.loaded then 'Going to load at ' || c.home_name
              when not c.unloaded then 'Driving to ' || c.at_name
              else 'Unloaded at ' || c.at_name || ', going home' end,
         c.to_wh, c.from_wh, c.at_name, c.home_name, c.capacity_kg - c.backhaul_kg,
         (select count(*) from w where w.truck_no = c.truck_no)::int,
         (select coalesce(sum(w.charged_kg), 0) from w where w.truck_no = c.truck_no),
         (select count(*) from w where w.truck_no = c.truck_no and w.run_kg <= w.free)::int,
         (select coalesce(sum(w.charged_kg), 0) from w where w.truck_no = c.truck_no and w.run_kg <= w.free),
         (select coalesce(round(sum(public.leg_revenue(w.awb, c.to_wh, c.from_wh))), 0) from w where w.truck_no = c.truck_no and w.run_kg <= w.free),
         round(c.km_ab * s.road_factor * (1 / s.km_per_l_loaded - 1 / s.km_per_l_empty) * s.diesel_price + s.trip_pay_base + s.trip_pay_per_km * c.km_ab),
         round(c.km_ab * s.road_factor * (1 / s.km_per_l_loaded + 1 / s.km_per_l_empty) * s.diesel_price
               + 2 * c.km_ab * s.road_factor * s.maint_per_km + s.trip_pay_base + s.trip_pay_per_km * c.km_ab),
         c.offered, c.accepted, c.last_ping_at
    from cur c, s
   order by c.unloaded desc, c.truck_no
$$;

-- Scanning: offer the return load when the truck is empty
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

  -- truck empty at this warehouse: offer the parcels waiting here for its drive home
  if p_mode = 'unload' and remaining = 0 and not coalesce((select tr.is_simulated from public.trucks tr where tr.truck_no = p_truck), true) then
    begin
      perform public.offer_return_load(p_truck, null, p_at);
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('result','ok','message','Scanned ' || o.awb,'scanned',v.parcels_scanned,
                            'expected',v.parcels_expected,'done',remaining = 0,'visit_id',v.id);
end $$;

-- Money: km and tolls of the drive home counted once
drop view if exists public.rule_flags;
drop view if exists public.trip_pnl;
create view public.trip_pnl with (security_invoker = true) as
with s as (select * from public.settings where id = 1),
t as (
  select l.truck_no, l.from_wh as origin_wh, l.to_wh as dest_wh, l.assigned_at,
         l.truck_no || '|' || l.from_wh || '|' || l.to_wh || '|' || floor(extract(epoch from l.assigned_at))::bigint as trip_key,
         count(*)::int as parcels, sum(o.charged_kg) as kg, sum(l.revenue_share) as revenue_legs,
         coalesce(sum(l.driver_pay), 0) as driver_pay, coalesce(max(l.to_wh_km), 0) as to_wh_km,
         bool_and(l.unloaded_at is not null) as completed, bool_or(l.backhaul) as backhaul
    from public.parcel_legs l join public.orders o on o.awb = l.awb
   where l.truck_no is not null
   group by l.truck_no, l.from_wh, l.to_wh, l.assigned_at),
x as (
  select t.*, wo.name as from_name, wd.name as to_name, tr.capacity_kg, tr.toll_class,
         coalesce(public.km(wo.lat, wo.lon, wd.lat, wd.lon), 0) as straight_km,
         lv.total_min as load_dwell_min, lv.last_scan_at as loaded_at,
         uv.total_min as unload_dwell_min, uv.last_scan_at as unloaded_at,
         least(case when t.backhaul then uv.last_scan_at else ret.at end, nx.at) as returned_at,
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

-- Permissions
revoke all on public.trip_pnl from anon;
revoke all on public.rule_flags from anon;
grant select on public.trip_pnl to authenticated;
grant select on public.rule_flags to authenticated;
revoke execute on function public.offer_return_load(text,text[],timestamptz) from public, anon;
grant execute on function public.offer_return_load(text,text[],timestamptz) to authenticated;
revoke execute on function public.return_load_matches() from public, anon;
grant execute on function public.return_load_matches() to authenticated;
revoke execute on function public.scan_parcel_at(text,text,text,text,timestamptz) from public, anon, authenticated;
