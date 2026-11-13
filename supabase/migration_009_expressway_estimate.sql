-- =====================================================================
-- Migration 009: closed-loop expressway tolls + cost estimate before a trip
-- Run once in Supabase -> SQL Editor, AFTER migration_008 (safe to run again).
--
-- 1. Closed-loop tolls (Delhi-Mumbai Expressway NE-4, Delhi-Meerut Expressway, ...): NHAI publishes
--    no single-journey fee per gantry, because the fee depends on where you enter and exit.
--    Before: every gantry was charged Rs 0 and flagged "toll rate missing".
--    Now: gantries are never charged one by one. When a truck passes two gantries in a row and drove
--    straight between them, that stretch is an expressway stretch: GPS km x the OFFICIAL per-km rate
--    you enter in table expressway_rates. With no rate entered, the km are flagged (R15), never guessed.
-- 2. estimate_leg(): the cost of a leg BEFORE it runs, with exactly the same formulas as trip_pnl.
-- =====================================================================

-- 1a. Which plazas are closed-loop gantries (from the NHAI name; kept up to date on every import)
alter table public.toll_plazas add column if not exists closed_loop boolean not null default false;
create or replace function public.set_closed_loop()
returns trigger language plpgsql as $$
begin
  new.closed_loop := new.name ~* 'close\s*loop|entry\s*exit';
  return new;
end $$;
drop trigger if exists toll_plazas_closed_loop on public.toll_plazas;
create trigger toll_plazas_closed_loop before insert or update of name on public.toll_plazas
  for each row execute function public.set_closed_loop();
update public.toll_plazas set closed_loop = (name ~* 'close\s*loop|entry\s*exit');

-- 1b. Official per-km fee for each closed-loop expressway and truck class. EMPTY on purpose:
--     enter the rate from NHAI's fee notification for that expressway, with its source.
create table if not exists public.expressway_rates (
  nh          text not null,          -- as in toll_plazas.nh, spaces removed, upper case (e.g. NE-4, 9, 334)
  toll_class  text not null check (toll_class in ('lcv','bus_truck','upto_3_axle','axle_4_6','hcm_eme','axle_7_plus')),
  rate_per_km numeric not null check (rate_per_km > 0),
  effective_from date not null,
  source_url  text not null,          -- the official notification
  primary key (nh, toll_class)
);
alter table public.expressway_rates enable row level security;
drop policy if exists staff_all on public.expressway_rates;
create policy staff_all on public.expressway_rates for all to authenticated using (true) with check (true);
revoke all on public.expressway_rates from anon;

create or replace function public.nh_key(p text) returns text language sql immutable as $$
  select upper(regexp_replace(coalesce(p, ''), '\s', '', 'g'))
$$;

-- 1c. Toll events remember the expressway stretch they charge
alter table public.toll_events add column if not exists km numeric;   -- only for closed-loop stretches
alter table public.toll_events add column if not exists closed_loop boolean not null default false;

-- 1d. GPS trigger: open plazas charged as before; closed-loop gantries charge the expressway stretch
create or replace function public.on_gps_ping()
returns trigger language plpgsql security definer set search_path = public as $$
declare t public.trucks; hours numeric; wh record; v_purpose text; tp record; v_rate numeric;
        prev record; v_km numeric; v_xrate numeric;
begin
  if new.recorded_at > now() + interval '5 minutes' then raise exception 'GPS time is in the future'; end if;
  select * into t from public.trucks where truck_no = new.truck_no;
  if t.last_ping_at is not null and new.recorded_at > t.last_ping_at then
    hours := extract(epoch from new.recorded_at - t.last_ping_at) / 3600;
    if hours > 0 and public.km(t.last_lat, t.last_lon, new.lat, new.lon) / hours > 120 then new.flag := 'impossible_jump'; end if;
  end if;
  if t.last_ping_at is null or new.recorded_at > t.last_ping_at then
    update public.trucks set last_lat = new.lat, last_lon = new.lon, last_speed_kmph = new.speed_kmph, last_ping_at = new.recorded_at
     where truck_no = new.truck_no;

    -- Toll plazas passed between the previous and this position (within 300 m of the path)
    if t.last_lat is not null and coalesce(new.flag, '') <> 'impossible_jump'
       and public.km(t.last_lat, t.last_lon, new.lat, new.lon) < 20 then
      for tp in select * from public.toll_plazas p
                 where p.active
                   and p.lat between least(t.last_lat, new.lat) - 0.01 and greatest(t.last_lat, new.lat) + 0.01
                   and p.lon between least(t.last_lon, new.lon) - 0.01 and greatest(t.last_lon, new.lon) + 0.01 loop
        continue when public.seg_dist_km(tp.lat, tp.lon, t.last_lat, t.last_lon, new.lat, new.lon) > 0.3;
        if not tp.closed_loop then
          -- open plaza: official single-journey fee; passing it again within 6 hours is the return trip
          if not exists (select 1 from public.toll_events e where e.truck_no = new.truck_no and e.plaza_id = tp.id
                           and e.at > new.recorded_at - interval '6 hours') then
            v_rate := case t.toll_class when 'lcv' then tp.rate_lcv when 'bus_truck' then tp.rate_bus_truck
                                        when 'upto_3_axle' then tp.rate_upto_3_axle when 'axle_4_6' then tp.rate_axle_4_6
                                        when 'hcm_eme' then tp.rate_hcm_eme when 'axle_7_plus' then tp.rate_axle_7_plus end;
            insert into public.toll_events (truck_no, plaza_id, plaza_name, toll_class, amount, rate_missing, at)
            values (new.truck_no, tp.id, tp.name, t.toll_class, coalesce(v_rate, 0), v_rate is null, new.recorded_at);
          end if;
        elsif not exists (select 1 from public.toll_events e where e.truck_no = new.truck_no and e.plaza_id = tp.id
                            and e.at > new.recorded_at - interval '30 minutes') then
          -- closed-loop gantry: the stretch since the previous gantry (within 3 h) is expressway driving,
          -- if the truck drove straight between them (GPS km at most 1.5 x the straight distance)
          select e.at, p.lat, p.lon into prev from public.toll_events e join public.toll_plazas p on p.id = e.plaza_id
           where e.truck_no = new.truck_no and e.closed_loop and e.plaza_id <> tp.id
             and e.at > new.recorded_at - interval '3 hours' order by e.at desc limit 1;
          v_km := null; v_xrate := null;
          if prev.at is not null then
            select coalesce(sum(d), 0) + public.km(t.last_lat, t.last_lon, new.lat, new.lon) into v_km
              from (select public.km(lag(p.lat) over w, lag(p.lon) over w, p.lat, p.lon) as d
                      from public.gps_pings p where p.truck_no = new.truck_no and p.recorded_at >= prev.at and p.recorded_at <= t.last_ping_at
                    window w as (order by p.recorded_at)) s where d is not null;
            if v_km > 1.5 * public.km(prev.lat, prev.lon, tp.lat, tp.lon) + 1 then v_km := null; end if;   -- left and came back: new entry
          end if;
          if v_km is not null then
            select r.rate_per_km into v_xrate from public.expressway_rates r
             where r.nh = public.nh_key(tp.nh) and r.toll_class = t.toll_class;
          end if;
          insert into public.toll_events (truck_no, plaza_id, plaza_name, toll_class, amount, rate_missing, at, km, closed_loop)
          values (new.truck_no, tp.id, tp.name, t.toll_class, coalesce(round(v_km * v_xrate), 0),
                  v_km is not null and v_xrate is null, new.recorded_at, round(v_km, 1), true);
        end if;
      end loop;
    end if;

    -- Arrival: within 500 m of a warehouse where this truck has parcels to load or unload
    for wh in select code from public.warehouses where active and public.km(new.lat, new.lon, lat, lon) <= 0.5 loop
      v_purpose := case when public.parcels_remaining(new.truck_no, wh.code, 'load') > 0 then 'load'
                        when public.parcels_remaining(new.truck_no, wh.code, 'unload') > 0 then 'unload' end;
      if v_purpose is not null and not exists (select 1 from public.warehouse_visits wv
           where wv.truck_no = new.truck_no and wv.warehouse = wh.code and wv.purpose = v_purpose and wv.departed_at is null) then
        insert into public.warehouse_visits (truck_no, warehouse, purpose, arrived_at, arrival_source, parcels_expected)
        values (new.truck_no, wh.code, v_purpose, new.recorded_at, 'gps', public.parcels_remaining(new.truck_no, wh.code, v_purpose));
      end if;
    end loop;

    -- Departure: more than 1 km away after scanning started
    update public.warehouse_visits vv set departed_at = new.recorded_at
      from public.warehouses wx
     where vv.truck_no = new.truck_no and vv.departed_at is null and vv.last_scan_at is not null
       and wx.code = vv.warehouse and public.km(new.lat, new.lon, wx.lat, wx.lon) > 1;
  end if;
  return new;
end $$;

-- 1e. Money and flags: missing open-plaza rates and uncosted expressway km are separate
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

drop function if exists public.estimate_leg(text,text,text,numeric,text[],numeric,numeric,int[],jsonb);

-- 2. Cost of one leg BEFORE it runs. Same formulas and settings as trip_pnl, so estimate and actual compare.
--    The page sends what only a road map knows: road km of the leg (OpenStreetMap routing), the toll
--    plazas within 300 m of that road with their km from the start [{id, at_km}], and km per closed-loop expressway.
create or replace function public.estimate_leg(
  p_from text, p_to text, p_class text, p_capacity numeric, p_awbs text[],
  p_road_km numeric, p_to_wh_km numeric default 0, p_plazas jsonb default '[]', p_xway jsonb default '[]')
returns jsonb language plpgsql stable set search_path = public as $$
declare s record; kg numeric; revenue numeric; n int; straight numeric; speed numeric; speed_src text;
        km_loaded numeric; km_empty numeric; hours numeric; unload_h numeric; n_plazas int;
        fuel numeric; maint numeric; driver numeric; tolls numeric := 0; tolls_xway numeric := 0;
        missing text[] := '{}'; xw record; xrate numeric; uncosted numeric := 0; cost numeric; warn text[] := '{}';
begin
  select * into s from public.settings where id = 1;
  select coalesce(sum(o.charged_kg), 0), count(*), coalesce(sum(public.leg_revenue(o.awb, p_from, p_to)), 0)
    into kg, n, revenue from public.orders o where o.awb = any(p_awbs);
  select coalesce(public.km(a.lat, a.lon, b.lat, b.lon), 0) into straight
    from public.warehouses a, public.warehouses b where a.code = p_from and b.code = p_to;
  -- speed: measured from GPS on this leg before; otherwise the simulator's cap
  select round(avg(avg_speed_kmh), 1) into speed from public.trip_pnl
   where origin_wh = p_from and dest_wh = p_to and km_from_gps and avg_speed_kmh > 0;
  speed_src := case when speed is null then 'ASSUMED (60 km/h, no GPS history on this leg yet)' else 'MEASURED (GPS, past trips on this leg)' end;
  speed := coalesce(speed, 60);
  km_loaded := p_road_km;
  km_empty  := p_road_km + coalesce(p_to_wh_km, 0);           -- to the warehouse before loading + empty return
  hours := (km_loaded + km_empty) / speed + 2 * (15 + 1.5 * n) / 60.0;
  fuel  := round((km_loaded / s.km_per_l_loaded + km_empty / s.km_per_l_empty) * s.diesel_price);
  maint := round((km_loaded + km_empty) * s.maint_per_km);
  driver := round(s.trip_pay_base + s.trip_pay_per_km * (coalesce(p_to_wh_km, 0) + straight));
  -- open plazas: charged again on the way back only if the truck passes it more than 6 hours later
  --   (time from the plaza to the destination, unloading, and back to the plaza)
  unload_h := (15 + 1.5 * n) / 60.0;
  select coalesce(sum(r * case when 2 * greatest(p_road_km - at_km, 0) / speed + unload_h > 6 then 2 else 1 end), 0),
         coalesce(array_agg(name) filter (where r is null), '{}'), count(*)
    into tolls, missing, n_plazas
    from (select p.name, (e->>'at_km')::numeric as at_km,
                 case p_class when 'lcv' then p.rate_lcv when 'bus_truck' then p.rate_bus_truck
                              when 'upto_3_axle' then p.rate_upto_3_axle when 'axle_4_6' then p.rate_axle_4_6
                              when 'hcm_eme' then p.rate_hcm_eme when 'axle_7_plus' then p.rate_axle_7_plus end as r
            from jsonb_array_elements(coalesce(p_plazas, '[]')) e
            join public.toll_plazas p on p.id = (e->>'id')::int and not p.closed_loop) q;
  -- closed-loop expressways: km x official per-km rate, both directions
  for xw in select public.nh_key(e->>'nh') as nh, (e->>'km')::numeric as km from jsonb_array_elements(coalesce(p_xway, '[]')) e loop
    select rate_per_km into xrate from public.expressway_rates where nh = xw.nh and toll_class = p_class;
    if xrate is null then uncosted := uncosted + 2 * xw.km;
    else tolls_xway := tolls_xway + round(2 * xw.km * xrate); end if;
  end loop;
  cost := fuel + tolls + tolls_xway + maint + driver;
  if revenue - cost < 0 then
    warn := warn || ('Below breakeven: loses ₹' || round(cost - revenue) || '. Needs '
             || case when kg > 0 and revenue > 0 then round(cost / (revenue / kg)) || ' kg' else 'more parcels' end
             || ', has ' || round(kg) || ' kg (' || round(kg / nullif(p_capacity, 0) * 100, 1) || '% full)');
  end if;
  if km_loaded > s.max_leg_km then warn := warn || ('Leg is ' || round(km_loaded) || ' km by road, over the ' || s.max_leg_km || ' km limit'); end if;
  if array_length(missing, 1) > 0 then warn := warn || ('No NHAI fee for this truck class at: ' || array_to_string(missing, ', ') || ' (counted as ₹0)'); end if;
  if uncosted > 0 then warn := warn || ('Expressway ' || round(uncosted) || ' km not costed: no official per-km rate in expressway_rates (counted as ₹0)'); end if;
  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'parcels', n, 'kg', kg, 'fill_pct', round(kg / nullif(p_capacity, 0) * 100, 1),
    'km_loaded', round(km_loaded, 1), 'km_empty', round(km_empty, 1), 'speed_kmh', speed, 'speed_source', speed_src,
    'hours', round(hours, 1), 'revenue', round(revenue), 'fuel', fuel, 'diesel_price', s.diesel_price,
    'tolls', tolls + tolls_xway, 'toll_plazas', n_plazas,
    'expressway_km_uncosted', round(uncosted, 1), 'maintenance', maint, 'driver', driver,
    'cost', cost, 'profit', round(revenue - cost),
    'breakeven_kg', case when kg > 0 and revenue > 0 then round(cost / (revenue / kg)) end,
    'warnings', to_jsonb(warn));
end $$;

-- 3. Permissions
revoke all on public.trip_pnl from anon;
revoke all on public.rule_flags from anon;
grant select on public.trip_pnl to authenticated;
grant select on public.rule_flags to authenticated;
revoke execute on function public.estimate_leg(text,text,text,numeric,text[],numeric,numeric,jsonb,jsonb) from public, anon;
grant execute on function public.estimate_leg(text,text,text,numeric,text[],numeric,numeric,jsonb,jsonb) to authenticated;
revoke execute on function public.set_closed_loop() from public, anon, authenticated;

-- check: closed-loop gantries found in your NHAI data, per expressway
select public.nh_key(nh) as expressway_nh, count(*) as closed_loop_gantries
  from public.toll_plazas where closed_loop group by 1 order by 2 desc;
