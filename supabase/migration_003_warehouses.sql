-- =====================================================================
-- Migration 003: warehouses
-- Run once in Supabase -> SQL Editor, AFTER migration_002 (safe to run again).
--
-- Trucks now collect parcels from warehouses, not from customers' doors:
--   * every order gets an origin warehouse (nearest to its pickup point)
--     and a destination warehouse (nearest to its delivery pincode);
--   * allocation sends one truck per route (origin -> destination warehouse),
--     the nearest free truck to the origin warehouse, filled up to capacity;
--   * the driver is paid per trip, split across that trip's parcels.
-- =====================================================================

-- 1. Warehouses
create table if not exists public.warehouses (
  code       text primary key check (code ~ '^[A-Z]{3}[0-9]{2}$'),   -- e.g. DEL01
  name       text not null,
  city       text not null,
  address    text,
  pincode    text check (pincode ~ '^[1-9][0-9]{5}$'),
  lat        double precision not null check (lat between 6 and 37),
  lon        double precision not null check (lon between 68 and 98),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.warehouses enable row level security;
drop policy if exists staff_all on public.warehouses;
create policy staff_all on public.warehouses for all to authenticated using (true) with check (true);

-- Starting warehouses (positions are approximate; edit them on the ops Warehouses tab)
insert into public.warehouses (code, name, city, address, pincode, lat, lon) values
 ('DEL01','Okhla Warehouse','Delhi','Okhla Industrial Area Phase 2','110020',28.5355,77.2750),
 ('GGN01','Gurugram Warehouse','Gurugram','Sector 37, Pace City','122001',28.4430,76.9950),
 ('NOI01','Noida Warehouse','Noida','Sector 63','201301',28.6260,77.3770),
 ('BOM01','Bhiwandi Warehouse','Mumbai','Bhiwandi logistics park','421302',19.2813,73.0483),
 ('BOM02','Navi Mumbai Warehouse','Mumbai','TTC Industrial Area, Turbhe','400703',19.0760,73.0170),
 ('PNQ01','Chakan Warehouse','Pune','Chakan MIDC','410501',18.7600,73.8630),
 ('BLR01','Hoskote Warehouse','Bengaluru','Hoskote industrial area','562114',13.0700,77.7980),
 ('MAA01','Sriperumbudur Warehouse','Chennai','Sriperumbudur','602105',12.9670,79.9420),
 ('CCU01','Dankuni Warehouse','Kolkata','Dankuni','712311',22.6800,88.2900),
 ('HYD01','Shamshabad Warehouse','Hyderabad','Shamshabad','501218',17.2400,78.4300),
 ('JAI01','Jaipur Warehouse','Jaipur','VKI Area','302013',26.9600,75.7700),
 ('LKO01','Lucknow Warehouse','Lucknow','Transport Nagar','226012',26.7800,80.9000),
 ('KNU01','Kanpur Warehouse','Kanpur','Panki Industrial Area','208020',26.4700,80.2300),
 ('AMD01','Ahmedabad Warehouse','Ahmedabad','Changodar','382213',22.9200,72.4500)
on conflict (code) do nothing;

-- 2. Orders know their warehouses
alter table public.orders add column if not exists origin_wh text references public.warehouses(code);
alter table public.orders add column if not exists dest_wh   text references public.warehouses(code);
create index if not exists orders_lane_idx on public.orders (origin_wh, dest_wh, status);

-- Driver pay per trip = base + per km (truck to origin warehouse + origin to destination warehouse).
-- Example rates: change them in the settings table.
alter table public.settings add column if not exists trip_pay_base   numeric not null default 300;
alter table public.settings add column if not exists trip_pay_per_km numeric not null default 3;

-- Nearest active warehouse to a point
create or replace function public.nearest_warehouse(p_lat double precision, p_lon double precision)
returns text language sql stable set search_path = public as $$
  select code from public.warehouses where active and p_lat is not null
  order by public.km(p_lat, p_lon, lat, lon) limit 1
$$;

-- Warehouse for a pincode: nearest to the pincode's centre if we know it,
-- otherwise the warehouse whose pincode shares the most leading digits (at least 2).
create or replace function public.warehouse_for_pincode(p_pin text)
returns text language plpgsql stable set search_path = public as $$
declare pc record; w text;
begin
  select lat, lon into pc from public.pincodes where pincode = p_pin;
  if pc.lat is not null then return public.nearest_warehouse(pc.lat, pc.lon); end if;
  select code into w from public.warehouses where active and pincode is not null
     and left(pincode, 2) = left(p_pin, 2)
   order by (case when left(pincode,4)=left(p_pin,4) then 4 when left(pincode,3)=left(p_pin,3) then 3 else 2 end) desc, code
   limit 1;
  return w;
end $$;

-- Fill in warehouses automatically on every new order
create or replace function public.set_order_warehouses()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.origin_wh is null then
    new.origin_wh := coalesce(public.nearest_warehouse(new.pickup_lat, new.pickup_lon),
                              public.warehouse_for_pincode(new.pickup_pincode));
  end if;
  if new.dest_wh is null then new.dest_wh := public.warehouse_for_pincode(new.delivery_pincode); end if;
  return new;
end $$;
drop trigger if exists orders_set_warehouses on public.orders;
create trigger orders_set_warehouses before insert on public.orders
  for each row execute function public.set_order_warehouses();

-- Existing orders get warehouses too
update public.orders set
  origin_wh = coalesce(origin_wh, public.nearest_warehouse(pickup_lat, pickup_lon), public.warehouse_for_pincode(pickup_pincode)),
  dest_wh   = coalesce(dest_wh, public.warehouse_for_pincode(delivery_pincode))
where origin_wh is null or dest_wh is null;

-- 3. Allocation by route
-- One truck per route (origin -> destination warehouse) per run: the nearest truck to the
-- origin warehouse that is available, has fresh GPS, has no other active job and has room.
-- Parcels on the same route join that truck until it is full; the rest get the next truck.
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
      from (select ord.*, min(ord.created_at) over (partition by ord.origin_wh, ord.dest_wh) as lane_first
              from public.orders ord where ord.status = 'booked' and ord.truck_no is null) x
      left join public.warehouses w on w.code = x.origin_wh
     order by x.lane_first, x.origin_wh, x.dest_wh, x.created_at
  loop
    awb := o.awb; truck_no := null; distance_km := null;
    if o.origin_wh is null then
      reason := 'No warehouse for this pickup. Add one near pincode ' || o.pickup_pincode;
      return next; continue;
    end if;
    lane := o.origin_wh || '>' || coalesce(o.dest_wh, '?');

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
       where tr.status = 'available'
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

-- Apply suggestions and set trip pay, split equally across the trip's parcels
create or replace function public.confirm_allocations(p_max_km numeric default null, p_fresh_min int default null)
returns int language plpgsql security definer set search_path = public as $$
declare r record; g record; n int := 0; s record; done text[] := '{}';
begin
  perform pg_advisory_xact_lock(4242);
  select * into s from public.settings where id = 1;
  for r in select * from public.suggest_allocations(p_max_km, p_fresh_min) where truck_no is not null loop
    update public.orders o set truck_no = r.truck_no, status = 'pickup_assigned', assigned_at = now(),
           pickup_distance_km = r.distance_km
     where o.awb = r.awb and o.status = 'booked' and o.truck_no is null;
    if found then
      update public.trucks t set load_kg = t.load_kg + (select charged_kg from public.orders where awb = r.awb)
       where t.truck_no = r.truck_no;
      insert into public.order_events (awb, status, truck_no, note, by_user)
      values (r.awb, 'pickup_assigned', r.truck_no, 'Truck ' || r.distance_km || ' km from warehouse', auth.uid());
      done := done || r.awb; n := n + 1;
    end if;
  end loop;

  -- trip pay for each truck + route that got parcels in this run
  for g in
    select o.truck_no, o.origin_wh, o.dest_wh, count(*) as parcels,
           max(o.pickup_distance_km) as to_wh_km,
           coalesce(public.km(wo.lat, wo.lon, wd.lat, wd.lon), 0) as trip_km
      from public.orders o
      join public.warehouses wo on wo.code = o.origin_wh
      left join public.warehouses wd on wd.code = o.dest_wh
     where o.awb = any(done)
     group by o.truck_no, o.origin_wh, o.dest_wh, wo.lat, wo.lon, wd.lat, wd.lon
  loop
    update public.orders set driver_pay = round((s.trip_pay_base + s.trip_pay_per_km * (g.to_wh_km + g.trip_km)) / g.parcels)
     where awb = any(done) and truck_no = g.truck_no and origin_wh = g.origin_wh
       and coalesce(dest_wh,'') = coalesce(g.dest_wh,'');
  end loop;
  return n;
end $$;

-- 4. Driver actions now end at the destination warehouse
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
    update public.orders set status = 'booked', truck_no = null, assigned_at = null, accepted_at = null,
           driver_pay = null, pickup_distance_km = null where awb = p_awb;
    new_status := 'booked';
  elsif p_action = 'picked_up' and o.status = 'driver_accepted' then
    update public.orders set status = 'picked_up' where awb = p_awb;     -- loaded at origin warehouse
    new_status := 'picked_up';
  elsif p_action = 'at_hub' and o.status = 'picked_up' then
    update public.trucks set load_kg = greatest(0, load_kg - o.charged_kg) where truck_no = o.truck_no;
    update public.orders set status = 'at_destination_hub' where awb = p_awb;   -- unloaded at destination warehouse
    new_status := 'at_destination_hub';
  else
    raise exception 'This job has already moved on. Pull down to refresh.';
  end if;
  insert into public.order_events (awb, status, truck_no, note, by_user)
  values (p_awb, new_status, o.truck_no, 'Driver: ' || p_action, auth.uid());
  return new_status;
end $$;

-- The same action for every parcel on one trip (truck + route)
create or replace function public.driver_trip_action(p_truck text, p_origin text, p_dest text, p_action text)
returns int language plpgsql security definer set search_path = public as $$
declare a text; n int := 0; from_status text[];
begin
  from_status := case p_action when 'accept' then array['pickup_assigned']
                               when 'decline' then array['pickup_assigned','driver_accepted']
                               when 'picked_up' then array['driver_accepted']
                               when 'at_hub' then array['picked_up'] end;
  if from_status is null then raise exception 'Unknown action'; end if;
  for a in select awb from public.orders where truck_no = p_truck and origin_wh = p_origin
             and coalesce(dest_wh,'') = coalesce(p_dest,'') and status = any(from_status) loop
    perform public.driver_action(a, p_action); n := n + 1;
  end loop;
  if n = 0 then raise exception 'This trip has already moved on. Pull down to refresh.'; end if;
  return n;
end $$;

-- 5. Tracking shows the warehouses (names only)
create or replace function public.track_order(p_awb text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'awb', o.awb, 'status', o.status, 'service', o.service,
    'from_pincode', o.pickup_pincode, 'to_pincode', o.delivery_pincode,
    'from_warehouse', wo.name, 'to_warehouse', wd.name,
    'charged_kg', o.charged_kg, 'pickup_date', o.pickup_date, 'eta_date', o.eta_date,
    'events', coalesce((select jsonb_agg(jsonb_build_object('status', e.status, 'at', e.at) order by e.at)
                        from public.order_events e where e.awb = o.awb), '[]'::jsonb))
  from public.orders o
  left join public.warehouses wo on wo.code = o.origin_wh
  left join public.warehouses wd on wd.code = o.dest_wh
  where o.awb = regexp_replace(p_awb, '\s', '', 'g')
$$;

-- 6. Permissions (Supabase opens new functions to the public by default)
revoke execute on function public.nearest_warehouse(double precision,double precision) from public, anon;
revoke execute on function public.warehouse_for_pincode(text) from public, anon;
revoke execute on function public.set_order_warehouses() from public, anon, authenticated;
revoke execute on function public.suggest_allocations(numeric,int) from public, anon;
revoke execute on function public.confirm_allocations(numeric,int) from public, anon;
revoke execute on function public.driver_action(text,text) from public, anon;
revoke execute on function public.driver_trip_action(text,text,text,text) from public, anon;
grant execute on function public.nearest_warehouse(double precision,double precision) to authenticated;
grant execute on function public.warehouse_for_pincode(text) to authenticated;
grant execute on function public.suggest_allocations(numeric,int) to authenticated;
grant execute on function public.confirm_allocations(numeric,int) to authenticated;
grant execute on function public.driver_action(text,text) to authenticated;
grant execute on function public.driver_trip_action(text,text,text,text) to authenticated;
grant execute on function public.track_order(text) to anon, authenticated;

do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.warehouses; exception when duplicate_object then null; end;
  end if;
end $$;
