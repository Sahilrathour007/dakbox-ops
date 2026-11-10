-- =====================================================================
-- Migration 004: warehouse scanning and loading time
-- Run once in Supabase -> SQL Editor, AFTER migration_003 (safe to run again).
--
-- Each time a truck comes to a warehouse to load or unload, a "visit" records:
--   arrived_at     GPS: truck within 500 m of the warehouse   (or the first scan, if no GPS)
--   first_scan_at  first parcel scanned                         -> waiting time = first scan - arrival
--   last_scan_at   last parcel scanned                          -> loading time = last scan - first scan
--   departed_at    GPS: truck more than 1 km away after loading -> exit time    = departure - last scan
-- Times come only from GPS and scans. A manager can only add a reason for a delay.
-- =====================================================================

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
