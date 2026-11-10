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
- Add or pause warehouses on the **Warehouses** tab. The 14 starting warehouses have approximate positions: check each one and correct it.

## Database updates, in order
Run once each in the Supabase SQL Editor, if your database is older than the feature:
1. `supabase/fix_function_permissions.sql`
2. `supabase/fix_awb_generator.sql`
3. `supabase/migration_002_driver_jobs.sql`
4. `supabase/migration_003_warehouses.sql`
