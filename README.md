# Dakbox: operations site + database

Staff site (login required): all orders, dispatch to the nearest truck, trucks, GPS.
This repo also holds the Supabase database setup (`supabase/schema.sql`) and the GPS receiver (`supabase/functions/gps-ingest`).
The customer booking site is in the separate **dakbox-customer** repo.

Supabase project: `kmqerwmfbpknrffadhoi`. `config.js` holds the project URL and the **anon** key, which is safe to publish.
Never commit the `service_role` key.

---

Two separate websites that share one Supabase database.

| Folder | Who uses it | What it does |
| --- | --- | --- |
| customer site (separate repo **dakbox-customer**) | Customers, public | Get a price, drop the pickup pin on a map, book, track by AWB |
| `ops/` | Your staff, login required | See all orders, allocate pickups to the nearest truck, manage trucks, GPS |
| `supabase/` | The database | Tables, prices, booking, tracking, allocation, GPS rules, access rules |

Customers can never read your tables. They can only use 3 functions: quote, book, track.
Staff must log in. Prices are set only in the database, so nobody can change a price in the browser.

---

## Setup (about 20 minutes)

### 1. Create the Supabase project
1. Sign up at supabase.com (free plan is enough to start) and create a project. Pick the **Mumbai (ap-south-1)** region.
2. Go to **SQL Editor → New query**, paste all of `supabase/schema.sql`, press **Run**.
3. Optional, for testing: run `supabase/example_trucks.sql` too. It adds 8 made-up trucks in Delhi and Mumbai.

### 2. Lock down staff accounts (do not skip)
1. **Authentication → Providers → Email**: turn **off** "Allow new users to sign up".
   Otherwise anyone could create an account and see every order.
2. **Authentication → Users → Add user**: create one login per staff member.

### 3. Connect both sites
1. **Project Settings → API**: copy the **Project URL** and the **anon public** key.
2. Paste both into `customer/config.js` **and** `ops/config.js`.
   Never use the `service_role` key in a website.

### 4. Put the sites online (free)
Any static host works. For example, Netlify Drop: drag the `customer` folder onto app.netlify.com/drop,
then do the same for the `ops` folder. You get two links. Give customers the first, staff the second.
Both must be served over **https**, or the customer's "Use my location" button won't work.

To try them on your own computer first:
```bash
cd dakbox && python3 -m http.server 8080
```
Then open http://localhost:8080/customer/ and http://localhost:8080/ops/

### 5. Connect real GPS (when you're ready)
1. Install the Supabase command-line tool, then deploy the receiver:
```bash
supabase functions deploy gps-ingest --no-verify-jwt
```
```bash
supabase secrets set INGEST_KEY=make-up-a-long-random-string
```
2. In the ops site, **Trucks** tab, fill in each truck's **GPS device ID (IMEI)**.
3. Give your GPS vendor the address shown on the ops **GPS** tab, plus the `INGEST_KEY`.
   Every ping they send updates the truck's position on the dispatch map.
4. Until then, drivers can share their phone's location from the driver page (below).

---

## How allocation works
For every order waiting for pickup, oldest first, the database picks the **nearest truck** that is:
- **available** (not full or off duty),
- has sent **GPS in the last 15 minutes**,
- has **enough free capacity** for the parcel's charged weight,
- is **within 25 km** of the pickup.

If no truck fits, it says why (too far, GPS old, truck full, off duty).
Staff press **Confirm** to apply. The 25 km and 15 minutes can be changed on the Dispatch tab.

## Maps: what's free and its limits
| Piece | Free option used | Limit |
| --- | --- | --- |
| Map tiles | OpenStreetMap via Leaflet | Fine for a few staff and normal customer traffic. For heavy traffic, switch the tile address to a provider's free tier (MapTiler, Stadia) |
| Pincode → map position | OpenStreetMap Nominatim | Max 1 search per second, some Indian pincodes missing. Customers can always tap the map instead |
| Distance | Straight line (calculated in the database) | Not road distance. Good enough for "nearest truck" to start |

## Where to change things
- **Prices and delivery days**: function `get_quote` in `schema.sql`. Re-run that function in the SQL Editor.
- **Pincode centres**: add rows to the `pincodes` table (used when a customer doesn't drop a pin).
- **Delete example trucks** (in the SQL Editor; their GPS pings go with them):
  `update orders set truck_no = null where truck_no in (select truck_no from trucks where driver_name like '%(example)');`
  then `delete from trucks where driver_name like '%(example)';`

## What is tested
The database and both sites were run end to end on a local Postgres with the same roles Supabase uses:
quote, booking, validation messages, random AWBs, tracking without personal data, customers blocked from tables,
staff login, allocation with reasons, confirm, adding a truck, simulated GPS, status change seen by the customer.
**Not tested here:** a live Supabase project, real map tiles, and the GPS Edge Function deployed on Supabase.

## Driver page (phone)
`driver.html`, e.g. https://sahilrathour007.github.io/dakbox-ops/driver.html

1. Driver signs in, picks their truck once, taps **Online**. The phone's location is shared every 30 seconds in the background, and the truck shows as available.
2. A pickup offer shows **what they earn**, **where** and **how far**. **Accept** or **Decline** (a declined job goes back for re-allocation).
3. After accepting: **Navigate** (Google Maps), **Call** the sender, then **Parcel picked up**, then **Dropped at hub**.
4. **Offline** stops location sharing and marks the truck off duty.

Driver pay = `driver_pay_base` + `driver_pay_per_km` x distance to pickup (settings table; example ₹40 + ₹8/km).
iPhone limit: Safari must stay open with the screen on while online.

## Database updates
If your database was created before the driver page, run `supabase/migration_002_driver_jobs.sql` once in the SQL Editor.

## Warehouses
Trucks collect parcels from **warehouses**, not from customers' doors.

- Every order is linked automatically to an **origin warehouse** (nearest to the pickup pin) and a **destination warehouse** (nearest to the delivery pincode).
- **Dispatch** groups waiting parcels into **trips** (origin → destination warehouse) and sends the nearest free truck to the origin warehouse, filled up to its capacity.
- **Driver pay per trip** = `trip_pay_base` + `trip_pay_per_km` × (truck to origin warehouse + origin to destination warehouse), split across the trip's parcels (settings table; example ₹300 + ₹3/km).
- The driver gets one card per trip: Accept → Navigate to origin warehouse → **All parcels loaded** → Navigate to destination → **Unloaded**.
- On the ops map, warehouses are magenta "W" markers; a yellow badge shows parcels waiting there.
- Warehouses are managed in Supabase: **Table Editor → warehouses** (add a row, edit lat/lon, or set `active` to false to pause one). The 14 starting warehouses have approximate positions: check each one and correct it.

## Database updates, in order
Run once each in the Supabase SQL Editor, if your database is older than the feature:
1. `supabase/fix_function_permissions.sql`
2. `supabase/fix_awb_generator.sql`
3. `supabase/migration_002_driver_jobs.sql`
4. `supabase/migration_003_warehouses.sql`
5. `supabase/migration_004_scans.sql`
6. `supabase/migration_005_money_rules.sql`
7. `supabase/migration_006_tolls_simulation.sql`
8. `supabase/migration_007_hub_spoke.sql` (hub-and-spoke network; safe to run again)
9. `supabase/migration_008_pincode_regions.sql` (every pincode finds its nearest warehouse; safe to run again)
10. `supabase/migration_009_expressway_estimate.sql` (closed-loop expressway tolls, cost estimate before a trip; safe to run again)
11. `supabase/migration_010_dispatch_real_trucks.sql` (dispatch reasons never name simulated trucks; safe to run again)
12. `supabase/migration_011_return_loads.sql` (return loads; safe to run again)
13. `supabase/migration_012_network_gaps.sql` (fills hub network gaps, re-routes waiting parcels; safe to run again)
14. `supabase/migration_013_auto_dispatch_returns.sql` (automatic dispatch, widening truck search, return trips with a stop; safe to run again)
N. `supabase/migration_015_leak_board.sql` (Leaks tab: where money leaks, ranked in rupees; safe to run again)

## Warehouse page (loading and unloading by scan)
`warehouse.html`, e.g. https://sahilrathour007.github.io/dakbox-ops/warehouse.html

1. Manager signs in and picks their warehouse once.
2. **Loading** shows trucks due to collect parcels here; **Unloading** shows trucks bringing parcels here. "Here" means the truck's GPS is within 500 m.
3. Tap a truck, then scan each parcel's barcode with the phone camera (or type the AWB). Wrong truck, wrong warehouse, unknown or repeated parcels are rejected with a message.
4. When every parcel is scanned, the trip moves on by itself: the driver's phone switches to "Drive to …" after loading, and parcels become "At destination hub" after unloading.
5. If the truck was at the warehouse 45 min or more, the manager picks a reason (truck late, parcels not ready, no loading bay, not enough staff, paperwork, other).

What is measured (ops site, **Loading times** tab), only from GPS and scans:
- **Waiting** = truck arrived (GPS within 500 m) → first scan
- **Loading** = first scan → last scan
- **Total** = arrival → last scan; departure = GPS more than 1 km away after loading
- If no GPS arrival was recorded, the first scan counts as arrival and the visit is marked "no GPS".

Customers print a label with a Code 128 barcode of the AWB from the booking confirmation.
Drivers can no longer mark parcels loaded or unloaded themselves: the scans do it.

## Money, dispatch rule and flags
**Money tab: the P&L of every trip** (a trip = the parcels one truck takes on one route in one dispatch):
- **Revenue** = freight × the truck's line-haul share (default ⅓). The truck is never credited the full parcel price.
- **Fuel** = (road km ÷ km per litre loaded + empty km to the warehouse ÷ km per litre empty) × diesel price. **Tolls** = road km × ₹ per km. Both are marked **EST** until you click **Enter real costs** and type the fuel-card and FASTag amounts.
- **Driver** = trip pay. **Fixed cost** = fixed ₹ per day ÷ 24 × cycle hours (actual once unloaded, otherwise estimated).
- **Profit**, **earning per truck-hour** (what one hour of this truck earned: the shadow price), **breakeven load** (kg needed to stop losing money on this route), **cost of waiting** at warehouses (waiting minutes × fixed cost per hour).
- **Rates used**: every example rate is editable at the bottom of the tab.

**Dispatch rule**: a trip is sent only when the truck is at least 60% full, **or** its oldest parcel has waited 24 hours (both editable). Until then it shows **Holding**. **Send now** sends it early but asks for a reason, which is saved with the trip.

**Status changes** on the Orders tab ask for a reason, which is saved in the parcel's history.

**Flags tab**: rules checked live: GPS lost on a trip (R2), impossible GPS jumps (R2), repeated rejected scans (R3), long waits with no reason (R5), finished trips still on estimated fuel or tolls (R6), trips losing money (R8), many manual changes by one person (R10), loading faster than 5 seconds per parcel (R11), orders with no warehouse (R12).

## Official costs: tolls, diesel, maintenance
| Cost | Source | How it is used |
| --- | --- | --- |
| Toll plazas | NHAI "National Highway (NH) Fee Plazas" list, 1,159 plazas (`data/nh_fee_plazas.csv`) | Which plazas exist |
| Plaza location and fee per vehicle class | NHAI Toll Information System, tis.nhai.gov.in | When a truck's GPS path passes within 300 m of a plaza, the plaza's official single-journey fee for the truck's toll class is charged (`toll_events`). A plaza with no fee for that class is charged ₹0 and flagged, never guessed. |
| Diesel | IndianOil price build-up of Diesel at Delhi, ₹95.20/L effective 01-Nov-2026 (iocl.com/petrol-diesel-price) | Fuel = loaded km ÷ km/l loaded + empty km ÷ km/l empty, × diesel price. Update the price on the Money tab when IndianOil revises it. |
| Maintenance and tyres | Assumption, ₹2 per km | Editable on the Money tab. |
| Fixed cost | Not counted | |

Distance and speed come from the truck's GPS positions: total km for the whole round trip (including the empty return), loaded km between loading and unloading, and moving speed = km ÷ hours between positions.

### Load the official toll plazas (once, and again after each April toll revision)
NHAI's site blocks most servers outside India, so run the importer on your own computer (Python 3, nothing to install):
```bash
cd dakbox-ops
python3 tools/import_nhai_tolls.py --upload your-staff-email@example.com
```
It downloads every plaza's location and fee table from NHAI, matches them to `data/nh_fee_plazas.csv`, and uploads them to Supabase (it asks for your Supabase password). Without `--upload` it writes `data/toll_plazas_import.sql`: paste that into the Supabase SQL Editor and Run. It also writes `data/toll_plazas_unmatched.csv` listing plazas from the NHAI list it could not match by name.

## Hub and spoke (no truck leg longer than 500 road km)
A driver may work 8 hours a day and must rest after 5 hours (Motor Transport Workers Act 1961, s.13 and s.15; Motor Vehicles Act 1988, s.91). At highway speeds that is about 400 to 500 km, so parcels travel hub to hub:
- Each warehouse is a **hub** (`is_hub = true`) or a **spoke**. A spoke connects only to its nearest hub. Okhla, Noida, Navi Mumbai and Kanpur are spokes.
- 16 **relay hubs** were added on the national highway corridors (Udaipur, Surat, Indore, Nagpur, Agra, Varanasi, Gaya, Dhanbad, Vijayawada, Nellore, Solapur, Kurnool, Hubballi, Chitradurga, Raipur, Bhubaneswar). Their positions are approximate: check them and correct them in Table Editor, warehouses.
- Links allowed: a spoke to its nearest hub, hub to hub up to `max_leg_km`, and any two warehouses within `settings.local_link_km` (60 road km). Kanpur is a hub; relay hubs at Jhansi, Bhopal, Adilabad, Berhampur and Visakhapatnam close the gaps in central India and on the east coast (migration 012). Routes are on average 9% longer than the direct road (worst 1.3x).
- When a parcel is booked, `plan_route` picks the shortest chain of warehouses where every hub-to-hub leg is at most `settings.max_leg_km` (500) road km (straight km × `road_factor`). Example: Okhla → Gurugram → Jaipur → Udaipur → Ahmedabad → Surat → Bhiwandi → Navi Mumbai.
- Dispatch, scanning and the driver page work **one leg at a time** (`orders.cur_wh` → `orders.next_wh`). When a parcel is unloaded at a middle hub, it becomes "In transit" there and waits for the truck of its next leg.
- Every leg is recorded in `parcel_legs`. The Money tab shows each leg as its own trip. Revenue is split across the legs by distance; each leg is costed with exactly the same formulas as before (GPS km including the empty return, NHAI tolls, IndianOil diesel, assumed maintenance, driver pay).
- New flags: **R12** order without a route, **R13** leg longer than the limit (from GPS km).
- After the update, parcels already on a truck finish their old direct trip as one leg. Waiting parcels get a route.

## Simulator (ops site, Simulator tab)
Pick a route with waiting parcels and a truck type. The simulator runs the whole hub-and-spoke relay, with one simulated truck per leg (numbers `SM01SI.....`), each based at its leg's start hub:
1. the truck is loaded by scan at its hub (15 min queue, 1.5 min per parcel);
2. it drives the real road route (OpenStreetMap routing) to the next hub, paying official NHAI tolls at each plaza it passes;
3. it is unloaded by scan there, then drives back to its base empty;
4. the parcels are sorted at the hub (`settings.hub_sort_minutes`, 30) and the next leg's truck takes them.
Truck speed follows the road (never above 60 km/h). The toll rule is unchanged: passing the same plaza again within 6 hours counts as the return trip and is not charged again.
**The whole relay always replays in 5 minutes**, however long it is, and simulated time ends at the current moment. Costs are worked out only from the simulated positions and scans, never from the replay speed, so a faster or slower replay gives exactly the same costs. The result per leg and in total appears at the end and on the Money tab. Simulated trucks are marked `is_simulated`, never get real parcels from dispatch, and are set to off duty afterwards.

## Closed-loop expressway tolls
On closed-loop expressways (Delhi-Mumbai Expressway NE-4, Delhi-Meerut Expressway, and others; NHAI names their gantries "Close Loop Toll" or "Entry Exit"), the fee depends on where you enter and exit, so NHAI publishes no fee per gantry.
- Gantries are never charged one by one. When a truck passes two gantries in a row and drove straight between them (GPS km at most 1.5 x the straight distance), that stretch is charged: **GPS km x the official per-km rate** from table `expressway_rates`.
- `expressway_rates` starts **empty on purpose**. Enter each expressway's official per-km rate per truck class, with the notification as `source_url` (Table Editor). `nh` is written without spaces, upper case, as in the toll data (e.g. `NE-4`, `9`, `334`).
- Until a rate is entered, the km are flagged as **R15 "Expressway toll not costed"** instead of silently counting as Rs 0.

## Cost estimate before a trip (warn only)
- **Dispatch:** every trip is estimated automatically as soon as its parcels are waiting (trips without a truck yet use an up-to-3-axle, 15,000 kg truck starting at the warehouse). The estimate shows km, hours, fuel, NHAI tolls, maintenance, driver, cost, revenue, profit and breakeven kg, with warnings (below breakeven, missing toll rates, expressway km not costed, leg over the limit). Sending a ready trip that is estimated to lose money asks for confirmation; nothing is blocked.
- **Simulator:** the estimate appears before you press Start, and the result shows actual cost next to estimated cost per leg.
- The database function `estimate_leg` uses the same settings and formulas as the Money tab; the page adds only the road km (OpenStreetMap routing), the plazas within 300 m of that road and the km on each expressway. Speed comes from GPS on past trips of the same leg, else 60 km/h (shown as ASSUMED).

## Trucks tab and Dispatch show real trucks only
Simulated trucks (`is_simulated`) are hidden there; they stay visible in the Simulator and on the Money tab. Dispatch → Zoom to → "Trucks with live GPS" jumps to trucks that sent GPS recently, and the map moves to a truck when it comes online.

## Return loads (backhaul)
A truck that has delivered drives home anyway. Parcels waiting at that warehouse whose next leg goes to the truck's home warehouse can ride along.
- **Automatic:** when the last parcel is scanned off a truck, the system offers the waiting parcels for its drive home (oldest first, as many as fit) to the driver.
- **Driver page:** the offer appears as a green **Return load** card (the phone vibrates); the driver accepts or declines. Loading and unloading are scanned as usual.
- **Ops → Return loads tab:** every real truck from dispatch until it is back home, its return trip, the parcels waiting on that lane, what fits, revenue, **extra cost** (diesel loaded instead of empty + driver trip pay), **own truck** cost (the same parcels on a separate truck, there and back, tolls not included), and the status. "Offer to driver" offers them by hand (e.g. after a decline).
- **Money:** a trip now ends when the truck starts its next job, so the drive home is counted once: on the return load if there is one, otherwise on the trip itself as before. Trips without a return load cost exactly what they did.

## Automatic dispatch (like a ride app)
- **Search:** the nearest free truck within 25 km, else 50, 100, 150 km (`settings.search_rings_km`, capped by Max distance). The Why column says how far the search went.
- **Offers expire:** a driver has `settings.offer_timeout_min` (10) minutes to accept. No answer, or a decline, and the offer goes to the next truck; that truck is not offered the same parcel again for 12 hours (`offer_log`).
- **Automatic:** `auto_dispatch()` expires unanswered offers and sends every trip that is ready under the fill rule. It runs every minute in the database with pg_cron (enable it in Supabase: Database, Extensions, pg_cron, then run migration 013 again). While the ops page is open it also runs from there. Switch it on or off in Dispatch.
- The fill rule still applies: a trip is sent when the truck is `min_fill_pct` full or the oldest parcel has waited `max_wait_hours`. "Send now" still works for early trips.

## Return trips with a stop
When a truck unloads away from home, the system compares going home directly with going home via one more warehouse that adds at most `settings.return_max_detour_pct` (25%) km. Each option is costed against driving home empty: extra diesel, maintenance and driver pay (same formulas as the Money tab; tolls not included). The option that earns most is offered: the first stop now, the next when the truck unloads there. A detour is only chosen if it earns more than driving home empty.
- **Driver page:** while driving out, a forecast of the way home; after unloading, the return load card with every stop, km and pay, and how long is left to answer.
- **Ops, Return loads tab:** each truck's plan (direct or via a warehouse), parcels, revenue, diesel, maintenance, driver, extra cost and gain vs an empty return, plus the other ways it compared.
- **Money:** each stop is its own trip; a return load ends when the truck is back home, so every km is counted once.

## Leaks tab: what to fix first
Money lost in the period, biggest first, in rupees. Each leak is a measured quantity times a rupee rate, and the leaks do not overlap:
1. **Paying for empty space**: cost of each loaded drive x share of the truck left empty.
2. **Driving empty**: empty km x (diesel + maintenance per km).
3. **Trucks standing idle**: hours not on a trip x fixed cost per truck-day / 24.
4. **Waiting at warehouses**: waiting hours x fixed cost per truck-day / 24.
5. **Detours**: km beyond the road distance between the warehouses (GPS trips).
6. **Diesel bills above expected**: bills entered vs km x official diesel price.
7. **Lanes that lose even when full**: cost minus revenue if the truck had been full.
Diesel and tolls are official; GPS, scans and bills are measured; maintenance per km and **fixed cost per truck-day** (`settings.fixed_cost_per_day`, default Rs 4,000, set it on the tab) are assumed. Assumed rates are varied 50% to 150%: "Rank holds? Yes" means the leak keeps its place either way, so it can be acted on before the costs are exact.
