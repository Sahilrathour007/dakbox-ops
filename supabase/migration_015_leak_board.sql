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
