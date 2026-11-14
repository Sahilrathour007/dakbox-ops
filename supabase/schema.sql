-- =====================================================================
-- Dakbox database (Supabase / Postgres)
-- Run this whole file once in Supabase: Dashboard -> SQL Editor -> New query -> Run.
--
-- Who can do what
--   Customers (not logged in, "anon"): get a quote, book, track by AWB.
--     They never read the tables directly, only through 3 functions.
--   Staff (logged in, "authenticated"): see and manage all orders and trucks,
--     run allocation, record GPS.
--   IMPORTANT: turn OFF public sign-ups in Supabase (Authentication -> Providers
--   -> Email -> "Allow new users to sign up" off) and invite staff yourself.
--   Otherwise anyone could sign up and see every order.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------

-- Pincode centres, used when a booking has no exact map pin.
create table if not exists public.pincodes (
  pincode text primary key check (pincode ~ '^[1-9][0-9]{5}$'),
  area    text not null,
  city    text not null,
  lat     double precision not null,
  lon     double precision not null
);

create table if not exists public.trucks (
  truck_no        text primary key check (truck_no ~ '^[A-Z]{2}[0-9]{1,2}[A-Z]{0,3}[0-9]{4}$'),
  driver_name     text not null,
  driver_phone    text check (driver_phone is null or driver_phone ~ '^[6-9][0-9]{9}$'),
  capacity_kg     numeric not null check (capacity_kg > 0),
  load_kg         numeric not null default 0 check (load_kg >= 0),
  status          text not null default 'available' check (status in ('available','full','off_duty')),
  gps_device_id   text unique,              -- IMEI from your GPS vendor
  last_lat        double precision,
  last_lon        double precision,
  last_speed_kmph numeric,
  last_ping_at    timestamptz,
  created_at      timestamptz not null default now()
);

-- AWB = 12 random digits starting with 7. Random, so nobody can guess other customers' AWBs.
-- Uses gen_random_uuid(), built into Postgres, so it works wherever extensions are installed.
create or replace function public.new_awb() returns text language sql volatile set search_path = pg_catalog as $$
  select '7' || lpad(((('x' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12))::bit(48)::bigint) % 100000000000)::text, 11, '0')
$$;

create table if not exists public.orders (
  awb              text primary key default public.new_awb(),
  created_at       timestamptz not null default now(),
  status           text not null default 'booked' check (status in
                     ('booked','pickup_assigned','picked_up','at_origin_hub','in_transit',
                      'at_destination_hub','out_for_delivery','delivered','cancelled')),
  service          text not null check (service in ('surface','express')),
  contents         text not null,
  sender_name      text not null,
  sender_phone     text not null check (sender_phone ~ '^[6-9][0-9]{9}$'),
  pickup_address   text not null,
  pickup_pincode   text not null check (pickup_pincode ~ '^[1-9][0-9]{5}$'),
  pickup_lat       double precision,
  pickup_lon       double precision,
  pickup_location_source text not null default 'none' check (pickup_location_source in ('map_pin','pincode_centre','none')),
  receiver_name    text not null,
  receiver_phone   text not null check (receiver_phone ~ '^[6-9][0-9]{9}$'),
  delivery_address text not null,
  delivery_pincode text not null check (delivery_pincode ~ '^[1-9][0-9]{5}$'),
  weight_kg        numeric not null check (weight_kg > 0 and weight_kg <= 50),
  length_cm        numeric not null check (length_cm > 0 and length_cm <= 150),
  width_cm         numeric not null check (width_cm > 0 and width_cm <= 150),
  height_cm        numeric not null check (height_cm > 0 and height_cm <= 150),
  volume_kg        numeric not null,
  charged_kg       numeric not null,
  zone             text not null,
  freight          numeric not null,
  gst              numeric not null,
  total            numeric not null,
  pickup_date      date not null,
  eta_date         date not null,
  truck_no         text references public.trucks(truck_no),
  assigned_at      timestamptz
);
create index if not exists orders_status_idx on public.orders (status, created_at);
create index if not exists orders_truck_idx  on public.orders (truck_no);

-- Every status change, append-only. This is the proof trail.
create table if not exists public.order_events (
  id         bigserial primary key,
  awb        text not null references public.orders(awb),
  status     text not null,
  truck_no   text,
  note       text,
  at         timestamptz not null default now(),
  by_user    uuid
);
create index if not exists order_events_awb_idx on public.order_events (awb, at);

-- Every GPS position, append-only.
create table if not exists public.gps_pings (
  id           bigserial primary key,
  truck_no     text not null references public.trucks(truck_no) on delete cascade,
  lat          double precision not null check (lat between -90 and 90),
  lon          double precision not null check (lon between -180 and 180),
  speed_kmph   numeric,
  recorded_at  timestamptz not null,          -- time on the device
  received_at  timestamptz not null default now(),
  source       text not null default 'tracker' check (source in ('tracker','phone','manual','simulated')),
  flag         text                            -- e.g. 'impossible_jump'
);
create index if not exists gps_pings_truck_idx on public.gps_pings (truck_no, recorded_at desc);

-- Settings the allocation reads. One row.
create table if not exists public.settings (
  id                 int primary key default 1 check (id = 1),
  max_distance_km    numeric not null default 25,
  gps_fresh_minutes  int not null default 15
);
insert into public.settings (id) values (1) on conflict do nothing;

-- ---------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------

-- Straight-line distance in km between two points (haversine).
create or replace function public.km(lat1 double precision, lon1 double precision,
                                      lat2 double precision, lon2 double precision)
returns double precision language sql immutable as $$
  select 2 * 6371 * asin(sqrt(
           power(sin(radians(lat2 - lat1) / 2), 2) +
           cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)))
$$;

-- Price and delivery time. The ONLY place prices are set. Example rates: change them here.
create or replace function public.get_quote(p_from text, p_to text, p_weight numeric,
                                            p_l numeric, p_w numeric, p_h numeric, p_service text)
returns table (zone text, volume_kg numeric, charged_kg numeric, freight numeric,
               gst numeric, total numeric, eta_days int)
language plpgsql stable as $$
declare
  z text; first_rate numeric; extra_rate numeric; slabs int; base numeric;
begin
  if p_from !~ '^[1-9][0-9]{5}$' or p_to !~ '^[1-9][0-9]{5}$' then
    raise exception 'Enter 6-digit pincodes';
  end if;
  if p_weight is null or p_weight <= 0 or p_weight > 50 then raise exception 'Weight must be 0.1 to 50 kg'; end if;
  if p_l <= 0 or p_w <= 0 or p_h <= 0 or greatest(p_l,p_w,p_h) > 150 then raise exception 'Each side must be 1 to 150 cm'; end if;
  if p_service not in ('surface','express') then raise exception 'Unknown service'; end if;

  z := case when left(p_from,3) = left(p_to,3) then 'city'
            when left(p_from,2) = left(p_to,2) then 'state'
            when left(p_from,1) = left(p_to,1) then 'region'
            else 'national' end;
  first_rate := case z when 'city' then 40 when 'state' then 50 when 'region' then 65 else 80 end;  -- first 500 g
  extra_rate := case z when 'city' then 30 when 'state' then 35 when 'region' then 45 else 60 end;  -- each extra 500 g

  zone := z;
  volume_kg := round(p_l * p_w * p_h / 5000.0, 1);
  charged_kg := greatest(p_weight, volume_kg);
  slabs := ceil(charged_kg / 0.5);
  base := first_rate + (slabs - 1) * extra_rate;
  if p_service = 'express' then base := round(base * 1.6); end if;
  freight := base;
  gst := round(base * 0.18);
  total := base + gst;
  eta_days := case p_service
                when 'express' then case z when 'city' then 1 when 'state' then 2 when 'region' then 2 else 3 end
                else case z when 'city' then 2 when 'state' then 3 when 'region' then 4 else 6 end end;
  return next;
end $$;

-- ---------------------------------------------------------------------
-- 3. Customer functions (the only doors open to the public)
-- ---------------------------------------------------------------------

-- Book a parcel. Price is recalculated here, so a customer can't change it in the browser.
create or replace function public.book_order(p jsonb)
returns table (awb text, total numeric, eta_date date, pickup_date date)
language plpgsql security definer set search_path = public as $$
declare
  q record; o public.orders; pdate date; plat double precision; plon double precision; src text := 'none';
begin
  pdate := coalesce((p->>'pickup_date')::date, current_date);
  if pdate < current_date or pdate > current_date + 14 then raise exception 'Pickup date must be today or within 14 days'; end if;
  if coalesce(p->>'sender_phone','')   !~ '^[6-9][0-9]{9}$' then raise exception 'Enter a valid 10-digit sender mobile number'; end if;
  if coalesce(p->>'receiver_phone','') !~ '^[6-9][0-9]{9}$' then raise exception 'Enter a valid 10-digit receiver mobile number'; end if;
  if length(trim(coalesce(p->>'sender_name',''))) < 2 or length(trim(coalesce(p->>'receiver_name',''))) < 2 then
    raise exception 'Enter sender and receiver names'; end if;
  if length(trim(coalesce(p->>'pickup_address',''))) < 6 or length(trim(coalesce(p->>'delivery_address',''))) < 6 then
    raise exception 'Enter full pickup and delivery addresses'; end if;
  if length(trim(coalesce(p->>'contents',''))) < 2 then raise exception 'Say what is inside the parcel'; end if;

  select * into q from public.get_quote(p->>'pickup_pincode', p->>'delivery_pincode',
         (p->>'weight_kg')::numeric, (p->>'length_cm')::numeric, (p->>'width_cm')::numeric,
         (p->>'height_cm')::numeric, p->>'service');

  -- Exact pin from the customer's map, if it is in India; else the pincode centre we know.
  plat := (p->>'pickup_lat')::double precision; plon := (p->>'pickup_lon')::double precision;
  if plat between 6 and 37 and plon between 68 and 98 then src := 'map_pin';
  else
    select pc.lat, pc.lon into plat, plon from public.pincodes pc where pc.pincode = p->>'pickup_pincode';
    src := case when plat is null then 'none' else 'pincode_centre' end;
  end if;

  insert into public.orders (service, contents, sender_name, sender_phone, pickup_address, pickup_pincode,
      pickup_lat, pickup_lon, pickup_location_source,
      receiver_name, receiver_phone, delivery_address, delivery_pincode,
      weight_kg, length_cm, width_cm, height_cm, volume_kg, charged_kg, zone, freight, gst, total,
      pickup_date, eta_date)
  values (p->>'service', left(trim(p->>'contents'),80), left(trim(p->>'sender_name'),80), p->>'sender_phone',
      left(trim(p->>'pickup_address'),300), p->>'pickup_pincode', plat, plon, src,
      left(trim(p->>'receiver_name'),80), p->>'receiver_phone', left(trim(p->>'delivery_address'),300), p->>'delivery_pincode',
      (p->>'weight_kg')::numeric, (p->>'length_cm')::numeric, (p->>'width_cm')::numeric, (p->>'height_cm')::numeric,
      q.volume_kg, q.charged_kg, q.zone, q.freight, q.gst, q.total,
      pdate, pdate + q.eta_days)
  returning * into o;

  insert into public.order_events (awb, status, note) values (o.awb, 'booked', 'Booked by customer');
  return query select o.awb, o.total, o.eta_date, o.pickup_date;
end $$;

-- Track a parcel by AWB. Returns no names, phones or addresses.
create or replace function public.track_order(p_awb text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'awb', o.awb, 'status', o.status, 'service', o.service,
    'from_pincode', o.pickup_pincode, 'to_pincode', o.delivery_pincode,
    'charged_kg', o.charged_kg, 'pickup_date', o.pickup_date, 'eta_date', o.eta_date,
    'events', coalesce((select jsonb_agg(jsonb_build_object('status', e.status, 'at', e.at) order by e.at)
                        from public.order_events e where e.awb = o.awb), '[]'::jsonb))
  from public.orders o where o.awb = regexp_replace(p_awb, '\s', '', 'g')
$$;

-- ---------------------------------------------------------------------
-- 4. Staff functions
-- ---------------------------------------------------------------------

-- Change an order's status and log it.
create or replace function public.set_order_status(p_awb text, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.orders set status = p_status where awb = p_awb;
  if not found then raise exception 'No order %', p_awb; end if;
  insert into public.order_events (awb, status, truck_no, note, by_user)
  select awb, p_status, truck_no, p_note, auth.uid() from public.orders where awb = p_awb;
  -- A delivered or cancelled parcel no longer weighs on its truck.
  if p_status in ('delivered','cancelled') then
    update public.trucks t set load_kg = greatest(0, t.load_kg - o.charged_kg)
    from public.orders o where o.awb = p_awb and t.truck_no = o.truck_no;
  end if;
end $$;

-- Suggest a truck for every order waiting for pickup.
-- Rule: oldest order first; nearest truck that is available, has fresh GPS,
-- has room, and is within the distance limit. Each suggestion uses up that room.
create or replace function public.suggest_allocations(p_max_km numeric default null, p_fresh_min int default null)
returns table (awb text, truck_no text, distance_km numeric, reason text)
language plpgsql stable security definer set search_path = public as $$
declare
  s record; o record; best record; near record; maxkm numeric; freshmin int;
  used_kg jsonb := '{}'::jsonb; fk numeric;
begin
  select * into s from public.settings where id = 1;
  maxkm := coalesce(p_max_km, s.max_distance_km);
  freshmin := coalesce(p_fresh_min, s.gps_fresh_minutes);

  for o in select * from public.orders where status = 'booked' and orders.truck_no is null order by created_at loop
    awb := o.awb; truck_no := null; distance_km := null;
    if o.pickup_lat is null then
      reason := 'Pickup location unknown: add a map pin or the pincode to the pincodes table';
      return next; continue;
    end if;

    -- nearest usable truck
    select t.truck_no as tno, public.km(o.pickup_lat, o.pickup_lon, t.last_lat, t.last_lon) as d,
           t.capacity_kg - t.load_kg as base_free
      into best
      from public.trucks t
     where t.status = 'available'
       and t.last_ping_at >= now() - make_interval(mins => freshmin)
       and public.km(o.pickup_lat, o.pickup_lon, t.last_lat, t.last_lon) <= maxkm
       and t.capacity_kg - t.load_kg
           - coalesce((used_kg ->> t.truck_no)::numeric, 0) >= o.charged_kg
     order by 2
     limit 1;

    if best.tno is not null then
      truck_no := best.tno; distance_km := round(best.d::numeric, 1);
      fk := coalesce((used_kg ->> best.tno)::numeric, 0) + o.charged_kg;
      used_kg := used_kg || jsonb_build_object(best.tno, fk);
      reason := 'Nearest usable truck, ' || round(best.base_free - fk) || ' kg free after this';
      return next; continue;
    end if;

    -- explain why nothing fits, using the nearest truck with any GPS
    select t.truck_no as tno, public.km(o.pickup_lat, o.pickup_lon, t.last_lat, t.last_lon) as d,
           t.status, t.last_ping_at, t.capacity_kg - t.load_kg - coalesce((used_kg ->> t.truck_no)::numeric, 0) as free
      into near from public.trucks t where t.last_lat is not null
     order by public.km(o.pickup_lat, o.pickup_lon, t.last_lat, t.last_lon) limit 1;
    reason := case
      when near.tno is null then 'No truck has sent GPS yet'
      when near.d > maxkm then 'Nearest truck ' || near.tno || ' is ' || round(near.d::numeric) || ' km away (limit ' || maxkm || ' km)'
      when near.status <> 'available' then 'Nearest truck ' || near.tno || ' is ' || replace(near.status, '_', ' ')
      when near.last_ping_at < now() - make_interval(mins => freshmin) then 'Nearest truck ' || near.tno || ': GPS last seen ' || round(extract(epoch from now() - near.last_ping_at) / 60) || ' min ago'
      else 'Nearest truck ' || near.tno || ' has only ' || round(near.free) || ' kg free' end;
    return next;
  end loop;
end $$;

-- Apply the current suggestions. Locked so two dispatchers can't double-book a truck.
create or replace function public.confirm_allocations(p_max_km numeric default null, p_fresh_min int default null)
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  perform pg_advisory_xact_lock(4242);
  for r in select * from public.suggest_allocations(p_max_km, p_fresh_min) where truck_no is not null loop
    update public.orders o set truck_no = r.truck_no, status = 'pickup_assigned', assigned_at = now()
     where o.awb = r.awb and o.status = 'booked' and o.truck_no is null;
    if found then
      update public.trucks t set load_kg = t.load_kg + (select charged_kg from public.orders where awb = r.awb)
       where t.truck_no = r.truck_no;
      insert into public.order_events (awb, status, truck_no, note, by_user)
      values (r.awb, 'pickup_assigned', r.truck_no, r.distance_km || ' km from pickup', auth.uid());
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- 5. GPS: every ping updates the truck's latest position
-- ---------------------------------------------------------------------
create or replace function public.on_gps_ping()
returns trigger language plpgsql security definer set search_path = public as $$
declare t public.trucks; hours numeric;
begin
  if new.recorded_at > now() + interval '5 minutes' then
    raise exception 'GPS time is in the future';
  end if;
  select * into t from public.trucks where truck_no = new.truck_no;
  if t.last_ping_at is not null and new.recorded_at > t.last_ping_at then
    hours := extract(epoch from new.recorded_at - t.last_ping_at) / 3600;
    if hours > 0 and public.km(t.last_lat, t.last_lon, new.lat, new.lon) / hours > 120 then
      new.flag := 'impossible_jump';      -- kept, but flagged
    end if;
  end if;
  if t.last_ping_at is null or new.recorded_at > t.last_ping_at then
    update public.trucks set last_lat = new.lat, last_lon = new.lon,
           last_speed_kmph = new.speed_kmph, last_ping_at = new.recorded_at
     where truck_no = new.truck_no;
  end if;
  return new;
end $$;
drop trigger if exists gps_ping_trigger on public.gps_pings;
create trigger gps_ping_trigger before insert on public.gps_pings
  for each row execute function public.on_gps_ping();

-- Raw records are never edited (rule R1). Only the database owner (you, in the SQL Editor)
-- may delete, e.g. to remove example data. The websites never can.
create or replace function public.block_edits() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' and current_user = 'postgres' then return old; end if;
  raise exception '% rows cannot be changed or deleted', tg_table_name;
end $$;
drop trigger if exists gps_pings_no_edit on public.gps_pings;
create trigger gps_pings_no_edit before update or delete on public.gps_pings
  for each row execute function public.block_edits();
drop trigger if exists order_events_no_edit on public.order_events;
create trigger order_events_no_edit before update or delete on public.order_events
  for each row execute function public.block_edits();

-- ---------------------------------------------------------------------
-- 6. Access rules (Row Level Security)
-- ---------------------------------------------------------------------
alter table public.pincodes     enable row level security;
alter table public.trucks       enable row level security;
alter table public.orders       enable row level security;
alter table public.order_events enable row level security;
alter table public.gps_pings    enable row level security;
alter table public.settings     enable row level security;

-- No policies for anon = customers can't read or write any table directly.
drop policy if exists staff_all on public.orders;
create policy staff_all on public.orders       for all    to authenticated using (true) with check (true);
drop policy if exists staff_all on public.trucks;
create policy staff_all on public.trucks       for all    to authenticated using (true) with check (true);
drop policy if exists staff_read on public.order_events;
create policy staff_read on public.order_events for select to authenticated using (true);
drop policy if exists staff_add on public.order_events;
create policy staff_add on public.order_events  for insert to authenticated with check (true);
drop policy if exists staff_read on public.gps_pings;
create policy staff_read on public.gps_pings    for select to authenticated using (true);
drop policy if exists staff_add on public.gps_pings;
create policy staff_add on public.gps_pings     for insert to authenticated with check (true);
drop policy if exists staff_all on public.pincodes;
create policy staff_all on public.pincodes     for all    to authenticated using (true) with check (true);
drop policy if exists staff_all on public.settings;
create policy staff_all on public.settings     for all    to authenticated using (true) with check (true);

-- Functions: Postgres lets everyone run new functions by default. Close that, then open per role.
revoke execute on function public.get_quote(text,text,numeric,numeric,numeric,numeric,text) from public;
revoke execute on function public.book_order(jsonb) from public;
revoke execute on function public.track_order(text) from public;
-- Supabase also grants every new function to "anon" directly, so revoke from anon too.
revoke execute on function public.set_order_status(text,text,text) from public, anon;
revoke execute on function public.suggest_allocations(numeric,int) from public, anon;
revoke execute on function public.confirm_allocations(numeric,int) from public, anon;
revoke execute on function public.new_awb() from public, anon, authenticated;
revoke execute on function public.block_edits() from public, anon, authenticated;
revoke execute on function public.on_gps_ping() from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon;

grant execute on function public.get_quote(text,text,numeric,numeric,numeric,numeric,text) to anon, authenticated;
grant execute on function public.book_order(jsonb)  to anon, authenticated;
grant execute on function public.track_order(text)  to anon, authenticated;
grant execute on function public.set_order_status(text,text,text) to authenticated;
grant execute on function public.suggest_allocations(numeric,int) to authenticated;
grant execute on function public.confirm_allocations(numeric,int) to authenticated;

-- Live updates on the operations site.
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.orders; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.trucks; exception when duplicate_object then null; end;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 7. Starting data: pincode centres (add more any time)
-- ---------------------------------------------------------------------
insert into public.pincodes (pincode, area, city, lat, lon) values
 ('110001','Connaught Place','Delhi',28.6315,77.2167), ('110017','Malviya Nagar','Delhi',28.5355,77.2100),
 ('110020','Okhla','Delhi',28.5450,77.2730),           ('110034','Pitampura','Delhi',28.6990,77.1310),
 ('110045','Dwarka','Delhi',28.5921,77.0460),          ('110085','Rohini','Delhi',28.7380,77.1010),
 ('110092','Shahdara','Delhi',28.6720,77.2960),        ('122001','Gurugram','Gurugram',28.4595,77.0266),
 ('201301','Noida','Noida',28.5700,77.3200),           ('400001','Fort','Mumbai',18.9338,72.8356),
 ('400050','Bandra West','Mumbai',19.0596,72.8295),    ('400069','Andheri East','Mumbai',19.1136,72.8697),
 ('400076','Powai','Mumbai',19.1176,72.9060),          ('400097','Malad','Mumbai',19.1870,72.8484),
 ('400601','Thane','Thane',19.1972,72.9722),           ('400703','Vashi','Navi Mumbai',19.0771,72.9986),
 ('411001','Pune Camp','Pune',18.5204,73.8567),        ('560001','Bengaluru Central','Bengaluru',12.9716,77.5946)
on conflict (pincode) do nothing;


-- ---------------------------------------------------------------------
-- 8. Driver jobs and driver pay (same as migration_002_driver_jobs.sql)
-- ---------------------------------------------------------------------
-- 1. New status "driver_accepted" between "pickup_assigned" and "picked_up"
alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check check (status in
  ('booked','pickup_assigned','driver_accepted','picked_up','at_origin_hub','in_transit',
   'at_destination_hub','out_for_delivery','delivered','cancelled'));

-- 2. What the driver earns for a pickup, and how far it was
alter table public.orders add column if not exists driver_pay numeric;
alter table public.orders add column if not exists pickup_distance_km numeric;
alter table public.orders add column if not exists accepted_at timestamptz;

-- Driver pay = base + per km from the truck to the pickup. Example rates: change them here.
alter table public.settings add column if not exists driver_pay_base   numeric not null default 40;
alter table public.settings add column if not exists driver_pay_per_km numeric not null default 8;

-- 3. Allocation now also sets the driver's pay for the job
create or replace function public.confirm_allocations(p_max_km numeric default null, p_fresh_min int default null)
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; s record;
begin
  perform pg_advisory_xact_lock(4242);
  select * into s from public.settings where id = 1;
  for r in select * from public.suggest_allocations(p_max_km, p_fresh_min) where truck_no is not null loop
    update public.orders o set truck_no = r.truck_no, status = 'pickup_assigned', assigned_at = now(),
           pickup_distance_km = r.distance_km,
           driver_pay = round(s.driver_pay_base + s.driver_pay_per_km * r.distance_km)
     where o.awb = r.awb and o.status = 'booked' and o.truck_no is null;
    if found then
      update public.trucks t set load_kg = t.load_kg + (select charged_kg from public.orders where awb = r.awb)
       where t.truck_no = r.truck_no;
      insert into public.order_events (awb, status, truck_no, note, by_user)
      values (r.awb, 'pickup_assigned', r.truck_no, r.distance_km || ' km from pickup', auth.uid());
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- 4. Staff status change: only release truck space if the parcel is still on the pickup truck
create or replace function public.set_order_status(p_awb text, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare before text;
begin
  select status into before from public.orders where awb = p_awb for update;
  if before is null then raise exception 'No order %', p_awb; end if;
  update public.orders set status = p_status where awb = p_awb;
  insert into public.order_events (awb, status, truck_no, note, by_user)
  select awb, p_status, truck_no, p_note, auth.uid() from public.orders where awb = p_awb;
  if before in ('pickup_assigned','driver_accepted','picked_up')
     and p_status not in ('pickup_assigned','driver_accepted','picked_up') then
    update public.trucks t set load_kg = greatest(0, t.load_kg - o.charged_kg)
    from public.orders o where o.awb = p_awb and t.truck_no = o.truck_no;
  end if;
end $$;

-- 5. Driver actions from the driver page
--   accept    : pickup_assigned -> driver_accepted
--   decline   : pickup_assigned/driver_accepted -> booked (goes back for re-allocation)
--   picked_up : driver_accepted -> picked_up
--   at_hub    : picked_up -> at_origin_hub (parcel leaves the pickup truck)
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
    update public.orders set status = 'picked_up' where awb = p_awb;
    new_status := 'picked_up';
  elsif p_action = 'at_hub' and o.status = 'picked_up' then
    update public.trucks set load_kg = greatest(0, load_kg - o.charged_kg) where truck_no = o.truck_no;
    update public.orders set status = 'at_origin_hub' where awb = p_awb;
    new_status := 'at_origin_hub';
  else
    raise exception 'This job has already moved on. Pull down to refresh.';
  end if;

  insert into public.order_events (awb, status, truck_no, note, by_user)
  values (p_awb, new_status, o.truck_no, 'Driver: ' || p_action, auth.uid());
  return new_status;
end $$;

revoke execute on function public.driver_action(text,text) from public, anon;
grant  execute on function public.driver_action(text,text) to authenticated;
revoke execute on function public.set_order_status(text,text,text) from public, anon;
grant  execute on function public.set_order_status(text,text,text) to authenticated;
revoke execute on function public.confirm_allocations(numeric,int) from public, anon;
grant  execute on function public.confirm_allocations(numeric,int) to authenticated;


-- ---------------------------------------------------------------------
-- 9. Warehouses (same as migration_003_warehouses.sql)
-- ---------------------------------------------------------------------
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


-- ---------------------------------------------------------------------
-- 10. Warehouse scanning and loading time (same as migration_004_scans.sql)
-- ---------------------------------------------------------------------
create table if not exists public.warehouse_visits (
  id               bigserial primary key,
  truck_no         text not null references public.trucks(truck_no) on delete cascade,
  warehouse        text not null references public.warehouses(code),
  purpose          text not null check (purpose in ('load','unload')),
  arrived_at       timestamptz,
  arrival_source   text check (arrival_source in ('gps','scan')),
  first_scan_at    timestamptz,
  last_scan_at     timestamptz,
  departed_at      timestamptz,
  parcels_expected int not null default 0,
  parcels_scanned  int not null default 0,
  delay_reason     text check (delay_reason in ('truck_late','parcels_not_ready','no_dock','not_enough_staff','paperwork','other')),
  delay_note       text,
  created_at       timestamptz not null default now()
);
create index if not exists visits_open_idx on public.warehouse_visits (truck_no, warehouse, purpose) where departed_at is null;
create index if not exists visits_wh_idx on public.warehouse_visits (warehouse, created_at desc);

create table if not exists public.parcel_scans (
  id         bigserial primary key,
  visit_id   bigint references public.warehouse_visits(id) on delete cascade,
  awb        text not null,
  warehouse  text not null,
  truck_no   text,
  scan_type  text not null check (scan_type in ('load','unload')),
  result     text not null check (result in ('ok','duplicate','wrong_truck','not_found')),
  scanned_at timestamptz not null default now(),
  by_user    uuid
);
create index if not exists scans_visit_idx on public.parcel_scans (visit_id, scanned_at);

alter table public.warehouse_visits enable row level security;
alter table public.parcel_scans enable row level security;
drop policy if exists staff_read on public.warehouse_visits;
create policy staff_read on public.warehouse_visits for select to authenticated using (true);
drop policy if exists staff_read on public.parcel_scans;
create policy staff_read on public.parcel_scans for select to authenticated using (true);
-- No insert/update policies: visits and scans are written only by the functions below.

drop trigger if exists parcel_scans_no_edit on public.parcel_scans;
create trigger parcel_scans_no_edit before update or delete on public.parcel_scans
  for each row execute function public.block_edits();

-- Times per visit, in minutes
create or replace view public.visit_times with (security_invoker = true) as
-- If a phone clock runs ahead, GPS arrival can land after the first scan: then the first scan counts as arrival.
select v.*, w.name as warehouse_name,
  round(extract(epoch from (v.first_scan_at - least(v.arrived_at, v.first_scan_at))) / 60) as wait_min,
  round(extract(epoch from (v.last_scan_at  - v.first_scan_at)) / 60)                      as loading_min,
  round(greatest(0, extract(epoch from (v.departed_at - v.last_scan_at))) / 60)           as exit_min,
  round(extract(epoch from (coalesce(v.departed_at, v.last_scan_at) - least(v.arrived_at, coalesce(v.first_scan_at, v.arrived_at)))) / 60) as total_min
from public.warehouse_visits v join public.warehouses w on w.code = v.warehouse;

-- Parcels still to scan for a truck at a warehouse
create or replace function public.parcels_remaining(p_truck text, p_wh text, p_purpose text)
returns int language sql stable set search_path = public as $$
  select count(*)::int from public.orders o where o.truck_no = p_truck and
    case when p_purpose = 'load'
         then o.origin_wh = p_wh and o.status in ('pickup_assigned','driver_accepted')
         else o.dest_wh   = p_wh and o.status = 'picked_up' end
$$;

-- Scan one parcel. Returns {result, message, scanned, expected, done, visit_id}
create or replace function public.scan_parcel(p_wh text, p_truck text, p_awb text, p_mode text)
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
    insert into public.parcel_scans (visit_id, awb, warehouse, truck_no, scan_type, result, by_user)
    values (v.id, coalesce(nullif(v_awb,''), p_awb), p_wh, p_truck, p_mode, 'not_found', auth.uid());
    return jsonb_build_object('result','not_found','message','No parcel with AWB ' || coalesce(nullif(v_awb,''), p_awb));
  end if;

  if v.id is not null and exists (select 1 from public.parcel_scans s where s.visit_id = v.id and s.awb = o.awb and s.result = 'ok') then
    insert into public.parcel_scans (visit_id, awb, warehouse, truck_no, scan_type, result, by_user)
    values (v.id, o.awb, p_wh, p_truck, p_mode, 'duplicate', auth.uid());
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
    insert into public.parcel_scans (visit_id, awb, warehouse, truck_no, scan_type, result, by_user)
    values (v.id, o.awb, p_wh, p_truck, p_mode, 'wrong_truck', auth.uid());
    return jsonb_build_object('result','wrong_truck','message',msg);
  end if;

  if v.id is null then
    insert into public.warehouse_visits (truck_no, warehouse, purpose, arrived_at, arrival_source)
    values (p_truck, p_wh, p_mode, now(), 'scan') returning * into v;
  end if;

  insert into public.parcel_scans (visit_id, awb, warehouse, truck_no, scan_type, result, by_user)
  values (v.id, o.awb, p_wh, p_truck, p_mode, 'ok', auth.uid());

  if p_mode = 'load' then
    update public.orders set status = 'picked_up', accepted_at = coalesce(accepted_at, now()) where orders.awb = o.awb;
    insert into public.order_events (awb, status, truck_no, note, by_user) values (o.awb, 'picked_up', p_truck, 'Loaded at ' || p_wh, auth.uid());
  else
    update public.orders set status = 'at_destination_hub' where orders.awb = o.awb;
    update public.trucks tr set load_kg = greatest(0, tr.load_kg - o.charged_kg) where tr.truck_no = p_truck;
    insert into public.order_events (awb, status, truck_no, note, by_user) values (o.awb, 'at_destination_hub', p_truck, 'Unloaded at ' || p_wh, auth.uid());
  end if;

  remaining := public.parcels_remaining(p_truck, p_wh, p_mode);
  update public.warehouse_visits wv set
     first_scan_at = coalesce(wv.first_scan_at, now()), last_scan_at = now(),
     parcels_scanned = wv.parcels_scanned + 1, parcels_expected = wv.parcels_scanned + 1 + remaining
   where wv.id = v.id returning * into v;

  return jsonb_build_object('result','ok','message','Scanned ' || o.awb,'scanned',v.parcels_scanned,
                            'expected',v.parcels_expected,'done',remaining = 0,'visit_id',v.id);
end $$;

-- Manager adds a reason for a slow visit (the only thing a person can add)
create or replace function public.set_delay_reason(p_visit bigint, p_reason text, p_note text default null)
returns void language sql security definer set search_path = public as $$
  update public.warehouse_visits set delay_reason = p_reason, delay_note = left(p_note, 200) where id = p_visit
$$;

-- GPS pings now also record arrival at, and departure from, warehouses
create or replace function public.on_gps_ping()
returns trigger language plpgsql security definer set search_path = public as $$
declare t public.trucks; hours numeric; wh record; v_purpose text;
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

-- Drivers no longer mark "loaded" or "unloaded" themselves: the warehouse scan does it.
create or replace function public.driver_trip_action(p_truck text, p_origin text, p_dest text, p_action text)
returns int language plpgsql security definer set search_path = public as $$
declare a text; n int := 0; from_status text[];
begin
  from_status := case p_action when 'accept' then array['pickup_assigned']
                               when 'decline' then array['pickup_assigned','driver_accepted'] end;
  if from_status is null then raise exception 'Loading and unloading are recorded by the warehouse scan'; end if;
  for a in select awb from public.orders where truck_no = p_truck and origin_wh = p_origin
             and coalesce(dest_wh,'') = coalesce(p_dest,'') and status = any(from_status) loop
    perform public.driver_action(a, p_action); n := n + 1;
  end loop;
  if n = 0 then raise exception 'This trip has already moved on. Pull down to refresh.'; end if;
  return n;
end $$;

-- Permissions
revoke execute on function public.scan_parcel(text,text,text,text) from public, anon;
revoke execute on function public.set_delay_reason(bigint,text,text) from public, anon;
revoke execute on function public.parcels_remaining(text,text,text) from public, anon;
revoke execute on function public.driver_trip_action(text,text,text,text) from public, anon;
revoke execute on function public.driver_action(text,text) from public, anon, authenticated;
grant execute on function public.scan_parcel(text,text,text,text) to authenticated;
grant execute on function public.set_delay_reason(bigint,text,text) to authenticated;
grant execute on function public.parcels_remaining(text,text,text) to authenticated;
grant execute on function public.driver_trip_action(text,text,text,text) to authenticated;
grant select on public.visit_times to authenticated;
revoke all on public.visit_times from anon;

do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.warehouse_visits; exception when duplicate_object then null; end;
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 11. Trip money, fill rule and flags (same as migration_005_money_rules.sql)
-- ---------------------------------------------------------------------
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


-- ---------------------------------------------------------------------
-- 12. Official toll plazas, GPS trip costs and simulation (same as migration_006_tolls_simulation.sql)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 13. Hub-and-spoke network, legs of max 500 road km (same as migration_007_hub_spoke.sql)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 14. Every pincode finds a warehouse (same as migration_008_pincode_regions.sql)
-- ---------------------------------------------------------------------
-- =====================================================================
-- Migration 008: every Indian pincode finds a warehouse (fixes routes ending in "?")
-- Run once in Supabase -> SQL Editor, AFTER migration_007 (safe to run again).
--
-- Why: a delivery pincode only found a warehouse if it was in the small `pincodes` table,
-- or if a warehouse pincode started with the same 2 digits. Chandigarh (16...), Dehradun (24...)
-- and even Kolkata (70..., our warehouse is 712...) found none, so the order had no route.
--
-- Now: pincode table first, else the postal region (first 3, then first 2 digits of the pincode,
-- as India Post assigns them) gives an approximate place, and the nearest warehouse serves it.
-- Region positions are APPROXIMATE (main sorting city of the region), good enough to pick a
-- warehouse. For exact positions, load India Post's pincode directory into `pincodes`.
-- =====================================================================

create table if not exists public.pin_regions (
  prefix text primary key check (prefix ~ '^[1-9][0-9]{1,2}$'),   -- first 2 or 3 digits of the pincode
  place  text not null,
  lat    double precision not null,
  lon    double precision not null
);
alter table public.pin_regions enable row level security;
drop policy if exists staff_read on public.pin_regions;
create policy staff_read on public.pin_regions for select to authenticated using (true);
revoke all on public.pin_regions from anon;

insert into public.pin_regions (prefix, place, lat, lon) values
 ('11','Delhi',28.61,77.21),('12','Haryana (south)',28.66,76.90),('13','Haryana (north)',29.69,76.99),
 ('14','Punjab (Ludhiana)',30.90,75.85),('15','Punjab (Bathinda)',30.21,74.95),('16','Chandigarh',30.73,76.78),
 ('17','Himachal Pradesh (Shimla)',31.10,77.17),('18','Jammu',32.73,74.86),('19','Srinagar',34.08,74.80),
 ('20','UP west (Aligarh)',27.88,78.08),('21','UP (Prayagraj)',25.44,81.85),('22','UP (Lucknow)',26.85,80.95),
 ('23','UP (Mirzapur)',25.15,82.57),('24','UP (Moradabad / Bareilly)',28.84,78.77),('25','UP (Meerut)',28.98,77.71),
 ('26','UP (Sitapur)',27.57,80.68),('27','UP east (Gorakhpur)',26.76,83.37),('28','UP (Agra)',27.18,78.01),
 ('30','Rajasthan (Jaipur)',26.91,75.79),('31','Rajasthan (Ajmer)',26.45,74.64),('32','Rajasthan (Kota)',25.18,75.83),
 ('33','Rajasthan (Bikaner)',28.02,73.31),('34','Rajasthan (Jodhpur)',26.24,73.02),
 ('36','Gujarat (Rajkot)',22.30,70.80),('37','Gujarat (Bhuj)',23.24,69.67),('38','Gujarat (Ahmedabad)',23.02,72.57),
 ('39','Gujarat (Bharuch / Surat)',21.70,72.98),
 ('40','Maharashtra (Mumbai)',19.08,72.88),('41','Maharashtra (Pune)',18.52,73.86),('42','Maharashtra (Nashik)',20.00,73.79),
 ('43','Maharashtra (Aurangabad)',19.88,75.34),('44','Maharashtra (Nagpur)',21.15,79.09),
 ('45','MP (Indore)',22.72,75.86),('46','MP (Bhopal)',23.26,77.41),('47','MP (Gwalior)',26.22,78.18),('48','MP (Jabalpur)',23.18,79.99),
 ('49','Chhattisgarh (Raipur)',21.25,81.63),
 ('50','Telangana (Hyderabad)',17.39,78.49),('51','AP (Kurnool)',15.83,78.04),('52','AP (Vijayawada)',16.51,80.65),
 ('53','AP (Visakhapatnam)',17.69,83.22),
 ('56','Karnataka (Bengaluru)',12.97,77.59),('57','Karnataka (Mysuru)',12.30,76.64),('58','Karnataka (Hubballi)',15.36,75.12),
 ('59','Karnataka (Belagavi)',15.85,74.50),
 ('60','Tamil Nadu (Chennai)',13.08,80.27),('61','Tamil Nadu (Thanjavur)',10.79,79.14),('62','Tamil Nadu (Madurai)',9.93,78.12),
 ('63','Tamil Nadu (Salem)',11.66,78.15),('64','Tamil Nadu (Coimbatore)',11.02,76.96),
 ('67','Kerala (Kozhikode)',11.26,75.78),('68','Kerala (Kochi)',9.93,76.27),('69','Kerala (Thiruvananthapuram)',8.52,76.94),
 ('70','West Bengal (Kolkata)',22.57,88.36),('71','West Bengal (Howrah)',22.59,88.31),('72','West Bengal (Midnapore)',22.42,87.32),
 ('73','West Bengal north (Siliguri)',26.73,88.40),('74','West Bengal (Krishnanagar)',23.40,88.50),
 ('75','Odisha (Bhubaneswar)',20.30,85.82),('76','Odisha (Berhampur)',19.31,84.79),('77','Odisha (Sambalpur)',21.47,83.97),
 ('78','Assam (Guwahati)',26.14,91.74),('79','North East (Shillong)',25.58,91.89),
 ('80','Bihar (Patna)',25.59,85.14),('81','Bihar (Bhagalpur)',25.24,86.97),('82','Bihar / Jharkhand (Gaya)',24.79,85.00),
 ('83','Jharkhand (Ranchi)',23.34,85.31),('84','Bihar (Muzaffarpur)',26.12,85.36),('85','Bihar (Purnia)',25.78,87.47),
 -- 3-digit regions that sit far from their 2-digit region's centre
 ('248','Dehradun',30.32,78.03),('249','Haridwar',29.95,78.16),('263','Nainital / Haldwani',29.22,79.51),
 ('221','Varanasi',25.32,82.97),('403','Goa',15.49,73.83),('413','Solapur / Latur',17.66,75.91),('416','Kolhapur / Sangli',16.70,74.24),
 ('575','Mangaluru',12.91,74.86),('826','Dhanbad',23.80,86.43),('828','Dhanbad',23.80,86.43),('831','Jamshedpur',22.80,86.20)
on conflict (prefix) do update set place = excluded.place, lat = excluded.lat, lon = excluded.lon;
-- 90-99 is the Army Postal Service: no region, so those orders are flagged (R12) for a person to handle.

create or replace function public.warehouse_for_pincode(p_pin text)
returns text language plpgsql stable set search_path = public as $$
declare pc record; w text;
begin
  select lat, lon into pc from public.pincodes where pincode = p_pin;
  if pc.lat is null then
    select lat, lon into pc from public.pin_regions
     where prefix in (left(p_pin, 3), left(p_pin, 2)) order by length(prefix) desc limit 1;
  end if;
  if pc.lat is not null then return public.nearest_warehouse(pc.lat, pc.lon); end if;
  select code into w from public.warehouses where active and pincode is not null
     and left(pincode, 2) = left(p_pin, 2)
   order by (case when left(pincode,4)=left(p_pin,4) then 4 when left(pincode,3)=left(p_pin,3) then 3 else 2 end) desc, code
   limit 1;
  return w;
end $$;

-- orders still waiting without a destination: find it and plan the route now
update public.orders set dest_wh = public.warehouse_for_pincode(delivery_pincode)
 where dest_wh is null and status = 'booked' and truck_no is null;
update public.orders
   set route = coalesce(public.plan_route(origin_wh, dest_wh), array[origin_wh, dest_wh]),
       cur_wh = origin_wh, leg_no = 1
 where status = 'booked' and truck_no is null and origin_wh is not null and dest_wh is not null
   and (route is null or route[array_length(route, 1)] is distinct from dest_wh);
update public.orders set next_wh = route[2]
 where status = 'booked' and truck_no is null and array_length(route, 1) >= 2 and next_wh is distinct from route[2];

revoke execute on function public.warehouse_for_pincode(text) from public, anon;
grant execute on function public.warehouse_for_pincode(text) to authenticated;

-- check: should list no rows (every waiting order has a full route)
select awb, delivery_pincode, dest_wh, route from public.orders
 where status = 'booked' and (dest_wh is null or next_wh is null) and origin_wh is distinct from dest_wh;

-- ---------------------------------------------------------------------
-- 15. Closed-loop expressway tolls and cost estimate (same as migration_009_expressway_estimate.sql)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 16. Dispatch reasons name real trucks only (same as migration_010_dispatch_real_trucks.sql)
-- ---------------------------------------------------------------------
-- =====================================================================
-- Migration 010: dispatch never names a simulated truck as the "nearest truck"
-- Run once in Supabase -> SQL Editor, AFTER migration_009 (safe to run again).
-- Simulated trucks already never got real parcels; now they are also left out of the
-- explanation shown when no truck fits ("Nearest truck SM01SIM... is off duty").
-- =====================================================================
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
      into near from public.trucks tr where tr.last_lat is not null and not tr.is_simulated
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

revoke execute on function public.suggest_allocations(numeric,int) from public, anon;
grant execute on function public.suggest_allocations(numeric,int) to authenticated;

-- ---------------------------------------------------------------------
-- 17. Return loads (same as migration_011_return_loads.sql)
-- ---------------------------------------------------------------------
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
drop function if exists public.return_load_matches();
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

-- ---------------------------------------------------------------------
-- 18. Hub network gaps fixed (same as migration_012_network_gaps.sql)
-- ---------------------------------------------------------------------
-- =====================================================================
-- Migration 012: fix hub network gaps (routes were up to 5x longer than the direct road)
-- Run once in Supabase -> SQL Editor, AFTER migration_011 (safe to run again).
--
-- Found: hub-to-hub links are at most 500 road km, and some neighbouring hubs were farther apart,
-- so routes went around the country (Kolkata -> Chennai via Delhi: 13 legs, 4,390 km instead of ~1,800).
-- Fix:
--   * 5 relay hubs fill the gaps: Jhansi, Bhopal, Adilabad (central India), Berhampur, Visakhapatnam (east coast);
--   * Kanpur becomes a hub (as a spoke, every parcel first went 75 km east to Lucknow);
--   * any two warehouses within settings.local_link_km (60 road km) may link directly (Okhla <-> Noida).
-- Result on the 14 main warehouses: routes 9% longer than the direct road on average (was 28%), worst 1.3x (was 5x).
-- Waiting parcels get the new route; parcels on a truck finish their current leg first.
-- Relay hub positions are approximate city centres: check them in Table Editor -> warehouses.
-- =====================================================================

insert into public.warehouses (code, name, city, address, lat, lon, is_hub) values
 ('JHS01','Jhansi Relay Hub','Jhansi','Relay hub, NH 44 corridor (approximate position)',25.4484,78.5685,true),
 ('BPL01','Bhopal Relay Hub','Bhopal','Relay hub, NH 46 corridor (approximate position)',23.2599,77.4126,true),
 ('ADB01','Adilabad Relay Hub','Adilabad','Relay hub, NH 44 corridor (approximate position)',19.6641,78.5320,true),
 ('BAM01','Berhampur Relay Hub','Berhampur','Relay hub, NH 16 corridor (approximate position)',19.3150,84.7941,true),
 ('VTZ01','Visakhapatnam Relay Hub','Visakhapatnam','Relay hub, NH 16 corridor (approximate position)',17.6868,83.2185,true)
on conflict (code) do nothing;
update public.warehouses set is_hub = true where code = 'KNU01';
alter table public.settings add column if not exists local_link_km numeric not null default 60;

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
      w := public.km(lats[u], lons[u], lats[j], lons[j]) * s.road_factor;
      -- links: spoke to its nearest hub; hub to hub up to max_leg_km; any two warehouses close together
      continue when not ((not hub[u] and nh[u] = j) or (not hub[j] and nh[j] = u)
                         or (hub[u] and hub[j] and w <= s.max_leg_km) or w <= s.local_link_km);
      if dist[u] + w < dist[j] then dist[j] := dist[u] + w; prev[j] := u; end if;
    end loop;
  end loop;
  if dist[b] >= 1e18 then return null; end if;
  path := array[codes[b]]; i := b;
  while i <> a loop i := prev[i]; path := codes[i] || path; end loop;
  return path;
end $$;

-- Re-route waiting parcels. At the origin: the whole route. At a middle hub: the legs already done stay, the rest is re-planned.
update public.orders o
   set route = case when o.leg_no <= 1 then p.r else o.route[1:o.leg_no] || p.r[2:] end,
       next_wh = p.r[2]
  from (select awb, public.plan_route(cur_wh, dest_wh) as r from public.orders
         where status in ('booked','in_transit') and truck_no is null and cur_wh is not null and dest_wh is not null) p
 where o.awb = p.awb and p.r is not null and array_length(p.r, 1) >= 2
   and o.status in ('booked','in_transit') and o.truck_no is null
   and o.route[o.leg_no:] is distinct from p.r;

revoke execute on function public.plan_route(text,text) from public, anon;
grant execute on function public.plan_route(text,text) to authenticated;

-- check: no route should be empty or much longer than the direct road
select count(*) filter (where route is null or next_wh is null) as waiting_without_route,
       count(*) as waiting_parcels
  from public.orders where status in ('booked','in_transit') and truck_no is null and origin_wh is distinct from dest_wh;

-- ---------------------------------------------------------------------
-- 19. Automatic dispatch, widening truck search, return trips with a stop (same as migration_013_auto_dispatch_returns.sql)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 20. Bug fixes (same as migration_014_bug_fixes.sql)
-- ---------------------------------------------------------------------
-- =====================================================================
-- Migration 014: bug fixes (run AFTER migration_013; safe to run again)
--  1. Orders tab status change: a parcel moved back to Booked / In transit, or Cancelled, stayed attached
--     to its truck with an open leg, so dispatch could never pick it up again. Now it is freed.
--  2. Parcels used by the simulator could be dispatched to a real truck (automatic dispatch, return loads)
--     between two simulated legs. They now stay with the simulator.
-- =====================================================================
create or replace function public.set_order_status(p_awb text, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare before text; v_truck text; v_leg int;
begin
  select status, truck_no, leg_no into before, v_truck, v_leg from public.orders where awb = p_awb for update;
  if before is null then raise exception 'No order %', p_awb; end if;
  update public.orders set status = p_status where awb = p_awb;
  insert into public.order_events (awb, status, truck_no, note, by_user)
  select awb, p_status, truck_no, p_note, auth.uid() from public.orders where awb = p_awb;
  if before in ('pickup_assigned','driver_accepted','picked_up')
     and p_status not in ('pickup_assigned','driver_accepted','picked_up') then
    update public.trucks t set load_kg = greatest(0, t.load_kg - o.charged_kg)
    from public.orders o where o.awb = p_awb and t.truck_no = o.truck_no;
  end if;
  -- back to waiting, or cancelled: off the truck, and its unfinished leg is removed
  if before in ('pickup_assigned','driver_accepted','picked_up') and p_status in ('booked','in_transit','cancelled') then
    delete from public.parcel_legs where awb = p_awb and leg_no = v_leg and truck_no = v_truck and unloaded_at is null;
    update public.orders set truck_no = null, assigned_at = null, accepted_at = null, driver_pay = null, pickup_distance_km = null
     where awb = p_awb;
  end if;
end $$;

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
              from public.orders ord where ord.status in ('booked','in_transit') and ord.truck_no is null
               and not exists (select 1 from public.parcel_legs sl join public.trucks st on st.truck_no = sl.truck_no where sl.awb = ord.awb and st.is_simulated)) x  -- simulator parcels stay with the simulator
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

create or replace function public.lane_fit(p_from text, p_to text, p_cap numeric)
returns table (awb text, kg numeric, revenue numeric) language sql stable set search_path = public as $$
  select q.awb, q.charged_kg, public.leg_revenue(q.awb, p_from, p_to)
    from (select o.awb, o.charged_kg, sum(o.charged_kg) over (order by o.created_at, o.awb) as run_kg
            from public.orders o
           where o.cur_wh = p_from and o.next_wh = p_to and o.status in ('booked','in_transit') and o.truck_no is null
             and not exists (select 1 from public.parcel_legs sl join public.trucks st on st.truck_no = sl.truck_no where sl.awb = o.awb and st.is_simulated)) q
   where q.run_kg <= p_cap
$$;

revoke execute on function public.set_order_status(text,text,text) from public, anon;
grant execute on function public.set_order_status(text,text,text) to authenticated;
revoke execute on function public.suggest_allocations(numeric,int) from public, anon;
grant execute on function public.suggest_allocations(numeric,int) to authenticated;
revoke execute on function public.lane_fit(text,text,numeric) from public, anon;
grant execute on function public.lane_fit(text,text,numeric) to authenticated;

-- ---------------------------------------------------------------------
-- 21. Leak board (same as migration_015_leak_board.sql)
-- ---------------------------------------------------------------------
-- =====================================================================
-- Migration 015: Leak board - where money leaks, in Rs per period, ranked
-- Run once in Supabase -> SQL Editor, AFTER migration_014 (safe to run again).
--
-- Every leak = a measured quantity (GPS km, scans, kg, hours, bills) x a rupee rate.
-- Rates that are assumed (maintenance per km, fixed cost per truck-day) are varied
-- 50%..150% to give a low and high figure, so you can see whether the ranking holds
-- even though the costs are not exact. The six leaks do not overlap.
-- =====================================================================

-- truck loan instalment + insurance + permits + driver salary, per truck per day (ASSUMED until you enter yours)
alter table public.settings add column if not exists fixed_cost_per_day numeric not null default 4000;

-- the six leaks for one set of assumed-rate factors (m = maintenance, f = fixed cost)
create or replace function public.leak_amounts(p_days int, p_sim boolean, m numeric, f numeric)
returns table (code text, amount numeric, qty numeric)
language sql stable set search_path = public as $$
  with s as (select * from public.settings where id = 1),
  t as (select p.*, public.km(a.lat, a.lon, b.lat, b.lon) as straight_km
          from public.trip_pnl p
          join public.trucks tr on tr.truck_no = p.truck_no and (p_sim or not tr.is_simulated)
          join public.warehouses a on a.code = p.origin_wh
          left join public.warehouses b on b.code = p.dest_wh
         where p.assigned_at >= now() - make_interval(days => p_days)),
  idle as (select tr.truck_no,
                  greatest(0, extract(epoch from now() - greatest(tr.created_at, now() - make_interval(days => p_days))) / 3600
                              - coalesce((select sum(t.cycle_hours) from t where t.truck_no = tr.truck_no), 0)) as hours
             from public.trucks tr where p_sim or not tr.is_simulated)
  -- 1. driving with nothing on board (returns, going to the pickup)
  select 'empty_km', round(sum(t.km_empty * (s.diesel_price / s.km_per_l_empty + m * s.maint_per_km))), round(sum(t.km_empty))
    from t, s
  union all
  -- 2. paying for space nobody bought: the loaded drive's cost x the empty share of the truck
  select 'empty_space', round(sum((t.km_loaded * (s.diesel_price / s.km_per_l_loaded + m * s.maint_per_km) + t.tolls + t.driver_pay)
                                  * (1 - least(t.fill_pct, 100) / 100))), round(avg(t.fill_pct), 1)
    from t, s
  union all
  -- 3. trucks standing idle between trips (fixed cost keeps running)
  select 'idle', round(sum(idle.hours * f * s.fixed_cost_per_day / 24)), round(sum(idle.hours)) from idle, s
  union all
  -- 4. waiting at warehouses before loading or unloading
  select 'waiting', round(coalesce(sum(v.wait_min / 60 * f * s.fixed_cost_per_day / 24), 0)), round(coalesce(sum(v.wait_min), 0) / 60, 1)
    from public.visit_times v join public.trucks tr on tr.truck_no = v.truck_no and (p_sim or not tr.is_simulated), s
   where v.created_at >= now() - make_interval(days => p_days)
  union all
  -- 5. km driven beyond the road distance between the warehouses (GPS trips only)
  select 'detour', round(coalesce(sum(greatest(0, t.km_loaded - t.straight_km * s.road_factor)
                                      * (s.diesel_price / s.km_per_l_loaded + m * s.maint_per_km)), 0)),
         round(coalesce(sum(greatest(0, t.km_loaded - t.straight_km * s.road_factor)), 0))
    from t, s where t.km_from_gps and t.straight_km > 0
  union all
  -- 6. diesel bills above what the km should have used (only trips with a bill entered)
  select 'fuel_gap', round(coalesce(sum(greatest(0, t.fuel - (t.km_loaded / s.km_per_l_loaded + t.km_empty / s.km_per_l_empty) * s.diesel_price)), 0)),
         count(*) filter (where t.fuel_is_actual)
    from t, s where t.fuel_is_actual
  union all
  -- 7. lanes priced so low they lose money even with a full truck
  select 'underpriced', round(coalesce(sum(greatest(0, (t.cost - t.maintenance * (1 - m)) - t.revenue * t.capacity_kg / t.kg)), 0)),
         count(*) filter (where (t.cost - t.maintenance * (1 - m)) > t.revenue * t.capacity_kg / t.kg)
    from t where t.kg > 0
$$;

-- the board: each leak with a low / likely / high figure, how sure it is, the formula and who fixes it
create or replace function public.leak_board(p_days int default 30, p_include_sim boolean default false)
returns table (code text, leak text, amount_low numeric, amount numeric, amount_high numeric, quantity text,
               basis text, formula text, fix text)
language sql stable set search_path = public as $$
  with lo as (select * from public.leak_amounts(p_days, p_include_sim, 0.5, 0.5)),
       mid as (select * from public.leak_amounts(p_days, p_include_sim, 1, 1)),
       hi as (select * from public.leak_amounts(p_days, p_include_sim, 1.5, 1.5)),
       meta (code, leak, unit, basis, formula, fix) as (values
    ('empty_km', 'Driving empty', ' empty km',
     'GPS km x official diesel + ASSUMED maintenance', 'empty km x (diesel / km per litre empty + maintenance per km)',
     'Return loads, nearer trucks, a home base where the loads start'),
    ('empty_space', 'Paying for empty space', '% average truck fill',
     'GPS km, scanned kg, official diesel + ASSUMED maintenance', 'cost of each loaded drive x share of the truck left empty',
     'Hold trips until fuller, smaller vehicles on thin lanes, more customers per lane'),
    ('idle', 'Trucks standing idle', ' idle truck-hours',
     'GPS / trip times x ASSUMED fixed cost per truck-day', 'idle hours x fixed cost per truck-day / 24',
     'More trips per truck, fewer trucks, sell spare days to the market'),
    ('waiting', 'Waiting at warehouses', ' hours waiting',
     'Scan and GPS times x ASSUMED fixed cost per truck-day', 'waiting hours x fixed cost per truck-day / 24',
     'Loading slots, staff at peak times, parcels ready before the truck arrives'),
    ('detour', 'Detours', ' extra km',
     'GPS km vs road distance, official diesel + ASSUMED maintenance', 'km beyond the road distance x cost per loaded km',
     'Check routes and drivers on the worst lanes'),
    ('fuel_gap', 'Diesel bills above expected', ' trips with a bill',
     'Diesel bills entered vs official diesel price x km', 'diesel bill - km x expected litres x price',
     'Fuel cards, tank checks, driver mileage targets'),
    ('underpriced', 'Lanes that lose even when full', ' trips',
     'Revenue and costs; maintenance ASSUMED', 'cost - revenue if the truck had been full',
     'Raise the price on these lanes, or stop selling them'))
  select m.code, m.leak, least(lo.amount, hi.amount), mid.amount, greatest(lo.amount, hi.amount),
         coalesce(mid.qty, 0) || m.unit, m.basis, m.formula, m.fix
    from meta m join mid using (code) join lo using (code) join hi using (code)
   order by mid.amount desc nulls last
$$;

revoke execute on function public.leak_amounts(int,boolean,numeric,numeric) from public, anon;
grant execute on function public.leak_amounts(int,boolean,numeric,numeric) to authenticated;
revoke execute on function public.leak_board(int,boolean) from public, anon;
grant execute on function public.leak_board(int,boolean) to authenticated;

-- check: the board for the last 30 days, simulations included
select leak, amount_low, amount, amount_high, quantity from public.leak_board(30, true);
