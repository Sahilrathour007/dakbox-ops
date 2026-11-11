-- =====================================================================
-- Migration 006: official toll plazas, toll charging from GPS, trip costs
-- from GPS distance, and truck simulation.
-- Run once in Supabase -> SQL Editor, AFTER migration_005 (safe to run again).
--
-- Data sources (official only):
--   * Toll plaza list: NHAI "National Highway (NH) Fee Plazas" (1,159 plazas).
--   * Toll plaza location and rates per vehicle class: NHAI Toll Information
--     System (tis.nhai.gov.in), loaded with tools/import_nhai_tolls.py.
--   * Diesel: IndianOil price build-up, Delhi, Rs 95.20/litre effective 01-Nov-2026.
-- Assumption (editable): maintenance and tyres Rs 2 per km. Fixed cost is not counted.
-- =====================================================================

-- 1. Toll plazas (official NHAI data, filled by the importer)
create table if not exists public.toll_plazas (
  id                 int primary key,           -- NHAI Toll Information System plaza id
  name               text not null,
  netc_code          text,                      -- from the NHAI fee plaza list
  pdf_s_no           int,                       -- row in the NHAI fee plaza list
  state              text,
  district           text,
  section            text,
  nh                 text,
  lat                double precision not null,
  lon                double precision not null,
  -- single-journey fee in Rs, per NHAI vehicle class
  rate_car           numeric,
  rate_lcv           numeric,
  rate_bus_truck     numeric,   -- bus / 2-axle truck
  rate_upto_3_axle   numeric,   -- up to 3-axle commercial vehicle
  rate_axle_4_6      numeric,   -- 4 to 6 axle
  rate_hcm_eme       numeric,   -- heavy construction machinery / earth-moving equipment
  rate_axle_7_plus   numeric,   -- 7 or more axle
  fee_effective_date text,
  source_url         text not null,
  fetched_at         timestamptz not null default now(),
  active             boolean not null default true
);
create index if not exists toll_plazas_latlon_idx on public.toll_plazas (lat, lon);
alter table public.toll_plazas enable row level security;
drop policy if exists staff_all on public.toll_plazas;
create policy staff_all on public.toll_plazas for all to authenticated using (true) with check (true);

-- 2. Trucks: toll class and simulation flag
alter table public.trucks add column if not exists toll_class text not null default 'upto_3_axle';
alter table public.trucks drop constraint if exists trucks_toll_class_check;
alter table public.trucks add constraint trucks_toll_class_check
  check (toll_class in ('lcv','bus_truck','upto_3_axle','axle_4_6','hcm_eme','axle_7_plus'));
alter table public.trucks add column if not exists is_simulated boolean not null default false;

-- 3. Rates: official diesel, assumed maintenance (fixed cost is no longer counted)
alter table public.settings add column if not exists maint_per_km  numeric not null default 2;
alter table public.settings add column if not exists diesel_source text;
update public.settings set diesel_price = 95.20,
       diesel_source = 'IndianOil price build-up of Diesel at Delhi, effective 01-Nov-2026 (iocl.com/petrol-diesel-price)'
 where id = 1 and (diesel_source is null or diesel_price = 100);

-- 4. Toll charges, recorded when a truck's GPS path passes a plaza
create table if not exists public.toll_events (
  id         bigserial primary key,
  truck_no   text not null references public.trucks(truck_no) on delete cascade,
  plaza_id   int not null references public.toll_plazas(id),
  plaza_name text not null,
  toll_class text not null,
  amount     numeric not null,              -- official single-journey fee for the truck's class
  rate_missing boolean not null default false,
  at         timestamptz not null
);
create index if not exists toll_events_truck_idx on public.toll_events (truck_no, at);
alter table public.toll_events enable row level security;
drop policy if exists staff_read on public.toll_events;
create policy staff_read on public.toll_events for select to authenticated using (true);
drop trigger if exists toll_events_no_edit on public.toll_events;
create trigger toll_events_no_edit before update or delete on public.toll_events
  for each row execute function public.block_edits();

-- Distance in km from point P to the segment A-B (flat-earth approximation, fine below ~20 km)
create or replace function public.seg_dist_km(plat double precision, plon double precision,
                                               alat double precision, alon double precision,
                                               blat double precision, blon double precision)
returns double precision language plpgsql immutable as $$
declare kx double precision := 111.32 * cos(radians((alat + blat) / 2)); ky double precision := 110.57;
        bx double precision := (blon - alon) * kx; byy double precision := (blat - alat) * ky;
        px double precision := (plon - alon) * kx; py double precision := (plat - alat) * ky;
        l2 double precision; t double precision;
begin
  l2 := bx * bx + byy * byy;
  if l2 = 0 then return sqrt(px * px + py * py); end if;
  t := greatest(0, least(1, (px * bx + py * byy) / l2));
  return sqrt((px - t * bx) ^ 2 + (py - t * byy) ^ 2);
end $$;

-- GPS ping trigger: position, warehouse arrival/departure, and now toll plazas
create or replace function public.on_gps_ping()
returns trigger language plpgsql security definer set search_path = public as $$
declare t public.trucks; hours numeric; wh record; v_purpose text; tp record; v_rate numeric;
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
        if public.seg_dist_km(tp.lat, tp.lon, t.last_lat, t.last_lon, new.lat, new.lon) <= 0.3
           and not exists (select 1 from public.toll_events e where e.truck_no = new.truck_no and e.plaza_id = tp.id
                             and e.at > new.recorded_at - interval '6 hours') then
          v_rate := case t.toll_class when 'lcv' then tp.rate_lcv when 'bus_truck' then tp.rate_bus_truck
                                      when 'upto_3_axle' then tp.rate_upto_3_axle when 'axle_4_6' then tp.rate_axle_4_6
                                      when 'hcm_eme' then tp.rate_hcm_eme when 'axle_7_plus' then tp.rate_axle_7_plus end;
          insert into public.toll_events (truck_no, plaza_id, plaza_name, toll_class, amount, rate_missing, at)
          values (new.truck_no, tp.id, tp.name, t.toll_class, coalesce(v_rate, 0), v_rate is null, new.recorded_at);
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

-- 5. Scanning with an explicit time (used by real scans with now(), and by the simulation)
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
     or (p_mode = 'load'   and (o.origin_wh <> p_wh or o.status not in ('pickup_assigned','driver_accepted')))
     or (p_mode = 'unload' and (o.dest_wh   <> p_wh or o.status <> 'picked_up')) then
    msg := case when o.truck_no is null then 'This parcel has no truck yet'
                when o.truck_no <> p_truck then 'Wrong truck: this parcel goes on ' || o.truck_no
                when p_mode = 'load' and o.origin_wh <> p_wh then 'Wrong warehouse: this parcel loads at ' || o.origin_wh
                when p_mode = 'unload' and o.dest_wh <> p_wh then 'Wrong warehouse: this parcel unloads at ' || o.dest_wh
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
    insert into public.order_events (awb, status, truck_no, note, by_user, at) values (o.awb, 'picked_up', p_truck, 'Loaded at ' || p_wh, auth.uid(), p_at);
  else
    update public.orders set status = 'at_destination_hub' where orders.awb = o.awb;
    update public.trucks tr set load_kg = greatest(0, tr.load_kg - o.charged_kg) where tr.truck_no = p_truck;
    insert into public.order_events (awb, status, truck_no, note, by_user, at) values (o.awb, 'at_destination_hub', p_truck, 'Unloaded at ' || p_wh, auth.uid(), p_at);
  end if;

  remaining := public.parcels_remaining(p_truck, p_wh, p_mode);
  update public.warehouse_visits wv set
     first_scan_at = coalesce(wv.first_scan_at, p_at), last_scan_at = p_at,
     parcels_scanned = wv.parcels_scanned + 1, parcels_expected = wv.parcels_scanned + 1 + remaining
   where wv.id = v.id returning * into v;

  return jsonb_build_object('result','ok','message','Scanned ' || o.awb,'scanned',v.parcels_scanned,
                            'expected',v.parcels_expected,'done',remaining = 0,'visit_id',v.id);
end $$;

create or replace function public.scan_parcel(p_wh text, p_truck text, p_awb text, p_mode text)
returns jsonb language sql security definer set search_path = public as $$
  select public.scan_parcel_at(p_wh, p_truck, p_awb, p_mode, now())
$$;

-- 6. Simulation (only for trucks marked is_simulated; times must not be in the future)
create or replace function public.sim_scan(p_wh text, p_truck text, p_awb text, p_mode text, p_at timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.trucks where truck_no = p_truck and is_simulated) then
    raise exception 'Simulated scans are only allowed for simulated trucks'; end if;
  if p_at > now() then raise exception 'Simulated time cannot be in the future'; end if;
  return public.scan_parcel_at(p_wh, p_truck, p_awb, p_mode, p_at);
end $$;

-- Give waiting parcels on one route to a simulated truck (as if dispatched and accepted)
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
   where awb = any(p_awbs) and status = 'booked' and truck_no is null;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'None of these parcels is waiting for a truck'; end if;
  select o.origin_wh, o.dest_wh into o1 from public.orders o where o.awb = any(p_awbs) and o.truck_no = p_truck limit 1;
  select coalesce(public.km(a.lat, a.lon, b.lat, b.lon), 0) into trip_km
    from public.warehouses a, public.warehouses b where a.code = o1.origin_wh and b.code = o1.dest_wh;
  update public.orders set driver_pay = round((s.trip_pay_base + s.trip_pay_per_km * (p_to_wh_km + coalesce(trip_km, 0))) / n)
   where awb = any(p_awbs) and truck_no = p_truck;
  update public.trucks t set load_kg = t.load_kg + (select coalesce(sum(charged_kg), 0) from public.orders where awb = any(p_awbs) and truck_no = p_truck)
   where t.truck_no = p_truck;
  insert into public.order_events (awb, status, truck_no, note, by_user, at)
  select awb, 'driver_accepted', p_truck, 'Simulation', auth.uid(), p_at from public.orders where awb = any(p_awbs) and truck_no = p_truck;
  return n;
end $$;

-- 7. Trip P&L, now from GPS: real km driven (loaded and empty, including the return),
--    official tolls charged on the way, official diesel, assumed maintenance. No fixed cost.
drop view if exists public.rule_flags;
drop view if exists public.trip_pnl;
create view public.trip_pnl with (security_invoker = true) as
with s as (select * from public.settings where id = 1),
t as (
  select o.truck_no, o.origin_wh, o.dest_wh, o.assigned_at,
         o.truck_no || '|' || o.origin_wh || '|' || coalesce(o.dest_wh, '') || '|' || floor(extract(epoch from o.assigned_at))::bigint as trip_key,
         count(*)::int as parcels, sum(o.charged_kg) as kg, sum(o.freight) as freight,
         coalesce(sum(o.driver_pay), 0) as driver_pay, coalesce(max(o.pickup_distance_km), 0) as to_wh_km,
         bool_and(o.status in ('at_destination_hub','out_for_delivery','delivered')) as completed
    from public.orders o
   where o.truck_no is not null and o.assigned_at is not null and o.origin_wh is not null and o.status <> 'cancelled'
   group by o.truck_no, o.origin_wh, o.dest_wh, o.assigned_at),
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
         round(y.freight * y.line_haul_share) as revenue,
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

-- 8. Flags (same rules; R6 now means "no official toll data / costs not confirmed")
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
  from public.orders o where o.status = 'booked' and o.origin_wh is null;

-- 9. Permissions
revoke all on public.trip_pnl from anon;
revoke all on public.rule_flags from anon;
grant select on public.trip_pnl to authenticated;
grant select on public.rule_flags to authenticated;
revoke execute on function public.seg_dist_km(double precision,double precision,double precision,double precision,double precision,double precision) from public, anon;
revoke execute on function public.scan_parcel_at(text,text,text,text,timestamptz) from public, anon, authenticated;
revoke execute on function public.scan_parcel(text,text,text,text) from public, anon;
revoke execute on function public.sim_scan(text,text,text,text,timestamptz) from public, anon;
revoke execute on function public.sim_assign(text,text[],timestamptz,numeric) from public, anon;
grant execute on function public.seg_dist_km(double precision,double precision,double precision,double precision,double precision,double precision) to authenticated;
grant execute on function public.scan_parcel(text,text,text,text) to authenticated;
grant execute on function public.sim_scan(text,text,text,text,timestamptz) to authenticated;
grant execute on function public.sim_assign(text,text[],timestamptz,numeric) to authenticated;
