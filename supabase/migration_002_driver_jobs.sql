-- =====================================================================
-- Migration 002: driver jobs and driver pay
-- Run once in Supabase -> SQL Editor (safe to run again).
-- Adds: a "driver accepted" step, driver pay per pickup, and the actions
-- a driver can take from the driver page (accept, decline, picked up, at hub).
-- =====================================================================

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
