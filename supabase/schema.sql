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
create or replace view public.trip_pnl with (security_invoker = true) as
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
