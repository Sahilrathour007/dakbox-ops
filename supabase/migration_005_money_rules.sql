-- =====================================================================
-- Migration 005: trip money (P&L), fill-rate dispatch rule, and rule flags
-- Run once in Supabase -> SQL Editor, AFTER migration_004 (safe to run again).
--
-- Adds what the system design called for but was not built yet:
--   * Trip P&L: the truck's share of revenue, fuel, tolls, driver, fixed cost,
--     profit, earning per truck-hour, fill rate, cost of waiting at warehouses.
--     Fuel and tolls are estimates until real figures are entered (marked "est.").
--   * Dispatch rule: a trip leaves when the truck is full enough OR its oldest
--     parcel has waited too long. Sending earlier needs a written reason.
--   * Flags: the rules checked live, so problems are visible, never silently fixed.
-- All rupee rates are examples: change them on the ops site, Money tab.
-- =====================================================================

-- 1. Rates (examples)
alter table public.settings add column if not exists diesel_price     numeric not null default 100;   -- ₹ per litre
alter table public.settings add column if not exists km_per_l_loaded  numeric not null default 4;
alter table public.settings add column if not exists km_per_l_empty   numeric not null default 5;
alter table public.settings add column if not exists toll_per_km      numeric not null default 2.5;   -- ₹ per km, estimate
alter table public.settings add column if not exists fixed_per_day    numeric not null default 2000;  -- EMI, insurance, permits
alter table public.settings add column if not exists line_haul_share  numeric not null default 0.3333; -- truck's share of freight
alter table public.settings add column if not exists road_factor      numeric not null default 1.3;   -- road km / straight-line km
alter table public.settings add column if not exists min_fill_pct     numeric not null default 60;    -- dispatch: leave when this full
alter table public.settings add column if not exists max_wait_hours   numeric not null default 24;    -- ...or when the oldest parcel waited this long

-- 2. Actual costs entered for a trip (replace the estimates)
create table if not exists public.trip_costs (
  trip_key   text primary key,            -- truck|origin|destination|assigned time
  fuel_rs    numeric check (fuel_rs >= 0),
  tolls_rs   numeric check (tolls_rs >= 0),
  updated_at timestamptz not null default now(),
  by_user    uuid default auth.uid()
);
alter table public.trip_costs enable row level security;
drop policy if exists staff_all on public.trip_costs;
create policy staff_all on public.trip_costs for all to authenticated using (true) with check (true);

-- 3. Trip P&L. A trip = the parcels one truck took on one route in one dispatch.
drop view if exists public.rule_flags;
drop view if exists public.trip_pnl;
create view public.trip_pnl with (security_invoker = true) as
with s as (select * from public.settings where id = 1),
t as (
  select o.truck_no, o.origin_wh, o.dest_wh, o.assigned_at,
         o.truck_no || '|' || o.origin_wh || '|' || coalesce(o.dest_wh, '') || '|' || floor(extract(epoch from o.assigned_at))::bigint as trip_key,
         count(*)::int as parcels, sum(o.charged_kg) as kg, sum(o.freight) as freight,
         coalesce(sum(o.driver_pay), 0) as driver_pay, coalesce(max(o.pickup_distance_km), 0) as empty_km,
         bool_and(o.status in ('at_destination_hub','out_for_delivery','delivered')) as completed
    from public.orders o
   where o.truck_no is not null and o.assigned_at is not null and o.origin_wh is not null and o.status <> 'cancelled'
   group by o.truck_no, o.origin_wh, o.dest_wh, o.assigned_at),
x as (
  select t.*, wo.name as from_name, wd.name as to_name, tr.capacity_kg,
         round((coalesce(public.km(wo.lat, wo.lon, wd.lat, wd.lon), 0) * s.road_factor)::numeric) as loaded_km,
         lv.total_min as load_dwell_min, uv.total_min as unload_dwell_min, uv.last_scan_at as unloaded_at,
         c.fuel_rs as fuel_actual, c.tolls_rs as tolls_actual,
         s.diesel_price, s.km_per_l_loaded, s.km_per_l_empty, s.toll_per_km, s.fixed_per_day, s.line_haul_share
    from t
    join public.warehouses wo on wo.code = t.origin_wh
    left join public.warehouses wd on wd.code = t.dest_wh
    join public.trucks tr on tr.truck_no = t.truck_no
    cross join s
    left join lateral (select v.total_min from public.visit_times v where v.truck_no = t.truck_no and v.warehouse = t.origin_wh
                         and v.purpose = 'load' and v.created_at >= t.assigned_at - interval '1 hour' order by v.id limit 1) lv on true
    left join lateral (select v.total_min, v.last_scan_at from public.visit_times v where v.truck_no = t.truck_no and v.warehouse = t.dest_wh
                         and v.purpose = 'unload' and v.created_at >= t.assigned_at order by v.id limit 1) uv on true
    left join public.trip_costs c on c.trip_key = t.trip_key),
y as (
  select x.*,
         round(x.freight * x.line_haul_share) as revenue,
         round((x.loaded_km / x.km_per_l_loaded + x.empty_km / x.km_per_l_empty) * x.diesel_price) as fuel_est,
         round(x.loaded_km * x.toll_per_km) as tolls_est,
         -- cycle hours: actual (assigned -> unloaded) when finished, else an estimate (30 km/h empty, 45 km/h loaded, 2 h at each end)
         case when x.completed and x.unloaded_at is not null
              then greatest(0.1, extract(epoch from (x.unloaded_at - x.assigned_at)) / 3600)
              else x.empty_km / 30 + x.loaded_km / 45 + 4 end as cycle_hours,
         x.completed and x.unloaded_at is not null as cycle_actual
    from x)
select y.trip_key, y.truck_no, y.origin_wh, y.dest_wh, y.from_name, y.to_name, y.assigned_at, y.completed,
       y.parcels, y.kg, y.capacity_kg, round(y.kg / y.capacity_kg * 100, 1) as fill_pct,
       y.empty_km, y.loaded_km, y.revenue,
       coalesce(y.fuel_actual, y.fuel_est) as fuel, y.fuel_actual is not null as fuel_is_actual,
       coalesce(y.tolls_actual, y.tolls_est) as tolls, y.tolls_actual is not null as tolls_is_actual,
       y.driver_pay, round(y.cycle_hours::numeric, 1) as cycle_hours, y.cycle_actual,
       round(y.fixed_per_day / 24 * y.cycle_hours) as fixed_cost,
       y.revenue - coalesce(y.fuel_actual, y.fuel_est) - coalesce(y.tolls_actual, y.tolls_est) - y.driver_pay as contribution,
       y.revenue - coalesce(y.fuel_actual, y.fuel_est) - coalesce(y.tolls_actual, y.tolls_est) - y.driver_pay
         - round(y.fixed_per_day / 24 * y.cycle_hours) as profit,
       round((y.revenue - coalesce(y.fuel_actual, y.fuel_est) - coalesce(y.tolls_actual, y.tolls_est) - y.driver_pay) / y.cycle_hours) as per_truck_hour,
       coalesce(y.load_dwell_min, 0) + coalesce(y.unload_dwell_min, 0) as dwell_min,
       round((coalesce(y.load_dwell_min, 0) + coalesce(y.unload_dwell_min, 0)) / 60.0 * y.fixed_per_day / 24) as dwell_cost,
       case when y.kg > 0 and y.revenue > 0 then
         round((coalesce(y.fuel_actual, y.fuel_est) + coalesce(y.tolls_actual, y.tolls_est) + y.driver_pay
                + y.fixed_per_day / 24 * y.cycle_hours) / (y.revenue / y.kg)) end as breakeven_kg
  from y;

-- 4. Dispatch with the fill rule.
-- A trip is sent when the truck is at least min_fill_pct full OR its oldest parcel has waited max_wait_hours.
-- p_send_now: AWBs whose trips should go now anyway; then p_reason is required and logged.
drop function if exists public.confirm_allocations(numeric,int);
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
          window w as (partition by sg.truck_no, o.origin_wh, o.dest_wh)) q;

  if forced_early and length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception 'Give a reason for sending a truck below its fill target';
  end if;

  for r in select * from public.suggest_allocations(p_max_km, p_fresh_min) where truck_no is not null and awb = any(v_send) loop
    update public.orders o set truck_no = r.truck_no, status = 'pickup_assigned', assigned_at = now(),
           pickup_distance_km = r.distance_km
     where o.awb = r.awb and o.status = 'booked' and o.truck_no is null;
    if found then
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
    select o.truck_no, o.origin_wh, o.dest_wh, count(*) as parcels, max(o.pickup_distance_km) as to_wh_km,
           coalesce(public.km(wo.lat, wo.lon, wd.lat, wd.lon), 0) as trip_km
      from public.orders o
      join public.warehouses wo on wo.code = o.origin_wh
      left join public.warehouses wd on wd.code = o.dest_wh
     where o.awb = any(done)
     group by o.truck_no, o.origin_wh, o.dest_wh, wo.lat, wo.lon, wd.lat, wd.lon
  loop
    update public.orders set driver_pay = round((s.trip_pay_base + s.trip_pay_per_km * (g.to_wh_km + g.trip_km)) / g.parcels)
     where awb = any(done) and truck_no = g.truck_no and origin_wh = g.origin_wh and coalesce(dest_wh,'') = coalesce(g.dest_wh,'');
  end loop;
  return n;
end $$;

-- 5. Rule flags, checked live. Severity: STOP = fix before trusting numbers, FLAG = look at it.
create or replace view public.rule_flags with (security_invoker = true) as
with s as (select * from public.settings where id = 1)
-- R2: truck on a trip with no recent GPS
select 'R2'::text as rule, 'FLAG'::text as severity, 'GPS lost on a trip'::text as title,
       t.truck_no || ' last sent GPS ' || coalesce(round(extract(epoch from now() - t.last_ping_at) / 60) || ' min ago', 'never') as detail,
       t.truck_no as ref, t.last_ping_at as at
  from public.trucks t, s
 where exists (select 1 from public.orders o where o.truck_no = t.truck_no and o.status in ('driver_accepted','picked_up'))
   and (t.last_ping_at is null or t.last_ping_at < now() - make_interval(mins => s.gps_fresh_minutes))
union all
-- R2: GPS position that is physically impossible
select 'R2', 'FLAG', 'Impossible GPS jump', p.truck_no || ' moved faster than 120 km/h', p.truck_no, p.recorded_at
  from public.gps_pings p where p.flag = 'impossible_jump' and p.recorded_at > now() - interval '7 days'
union all
-- R3: scans that did not match the truck or did not exist
select 'R3', 'FLAG', 'Rejected scans', count(*) || ' wrong or unknown parcels scanned at ' || ps.warehouse || ' in 7 days', ps.warehouse, max(ps.scanned_at)
  from public.parcel_scans ps where ps.result in ('wrong_truck','not_found') and ps.scanned_at > now() - interval '7 days'
 group by ps.warehouse having count(*) >= 3
union all
-- R5: long warehouse visit with no reason
select 'R5', 'FLAG', 'Long wait, no reason', v.truck_no || ' spent ' || v.total_min || ' min at ' || v.warehouse_name, v.warehouse, v.arrived_at
  from public.visit_times v where v.total_min >= 45 and v.delay_reason is null and v.last_scan_at is not null
union all
-- R6: finished trip still costed from estimates
select 'R6', 'FLAG', 'Fuel or tolls estimated', p.truck_no || ' ' || p.origin_wh || '→' || coalesce(p.dest_wh, '?') || ': enter actual fuel and tolls', p.trip_key, p.assigned_at
  from public.trip_pnl p where p.completed and not (p.fuel_is_actual and p.tolls_is_actual)
union all
-- R8: trip losing money
select 'R8', 'FLAG', 'Trip losing money', p.truck_no || ' ' || p.origin_wh || '→' || coalesce(p.dest_wh, '?') || ': ₹' || p.profit || ' at ' || p.fill_pct || '% full', p.trip_key, p.assigned_at
  from public.trip_pnl p where p.profit < 0
union all
-- R10: manual status changes and early dispatches, per person, last 7 days
select 'R10', 'FLAG', 'Many manual changes', count(*) || ' manual status changes or early dispatches in 7 days', coalesce(e.by_user::text, 'unknown'), max(e.at)
  from public.order_events e
 where e.at > now() - interval '7 days' and (e.note like 'Changed in ops%' or e.note like '%Sent below fill target%')
 group by e.by_user having count(*) >= 5
union all
-- R11: loading faster than is physically likely (scans possibly skipped or faked)
select 'R11', 'FLAG', 'Loading suspiciously fast', v.truck_no || ' at ' || v.warehouse_name || ': ' || v.parcels_scanned || ' parcels in ' || coalesce(v.loading_min, 0) || ' min', v.warehouse, v.first_scan_at
  from public.visit_times v
 where v.parcels_scanned >= 5 and v.last_scan_at is not null
   and extract(epoch from (v.last_scan_at - v.first_scan_at)) / v.parcels_scanned < 5
union all
-- R12: orders the system cannot place
select 'R12', 'STOP', 'Order without warehouse', o.awb || ' from pincode ' || o.pickup_pincode || ' has no origin warehouse', o.awb, o.created_at
  from public.orders o where o.status = 'booked' and o.origin_wh is null;

-- 6. Permissions
revoke all on public.trip_pnl from anon;
revoke all on public.rule_flags from anon;
grant select on public.trip_pnl to authenticated;
grant select on public.rule_flags to authenticated;
revoke execute on function public.confirm_allocations(numeric,int,text[],text) from public, anon;
grant execute on function public.confirm_allocations(numeric,int,text[],text) to authenticated;
