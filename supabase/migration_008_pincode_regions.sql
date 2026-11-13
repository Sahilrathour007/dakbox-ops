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
