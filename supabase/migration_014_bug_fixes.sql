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
