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
