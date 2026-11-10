// Supabase Edge Function: receives GPS pings from your tracker vendor (or a driver app)
// and saves them. Each saved ping updates the truck's latest position automatically.
//
// Deploy:   supabase functions deploy gps-ingest --no-verify-jwt
// Secret:   supabase secrets set INGEST_KEY=<a long random string>
// Vendor sends: POST https://<project>.supabase.co/functions/v1/gps-ingest
//               header  x-ingest-key: <INGEST_KEY>
//               body    one ping, or a list of pings:
//   { "device_id": "868123045678901", "lat": 28.545, "lon": 77.273,
//     "speed_kmph": 18, "time": "2026-11-10T09:42:10+05:30" }
//   ("truck_no" can be sent instead of "device_id".)
import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, // server-only key, never put in a website
);

type Ping = { device_id?: string; truck_no?: string; lat: number; lon: number; speed_kmph?: number; time: string; source?: string };

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);
  if (req.headers.get("x-ingest-key") !== Deno.env.get("INGEST_KEY")) return json({ error: "Wrong ingest key" }, 401);

  let body: Ping | Ping[];
  try { body = await req.json(); } catch { return json({ error: "Body must be JSON" }, 400); }
  const pings = Array.isArray(body) ? body : [body];
  if (pings.length > 500) return json({ error: "Send at most 500 pings per request" }, 413);

  // Map device IDs to truck numbers once per request.
  const { data: trucks, error } = await db.from("trucks").select("truck_no, gps_device_id");
  if (error) return json({ error: error.message }, 500);
  const byDevice = new Map(trucks.filter((t) => t.gps_device_id).map((t) => [t.gps_device_id, t.truck_no]));
  const known = new Set(trucks.map((t) => t.truck_no));

  const rows = [], rejected: { ping: Ping; reason: string }[] = [];
  for (const p of pings) {
    const truck = p.truck_no?.toUpperCase().replace(/[\s-]/g, "") ?? byDevice.get(p.device_id ?? "");
    const t = Date.parse(p.time);
    if (!truck || !known.has(truck)) rejected.push({ ping: p, reason: "unknown truck or device" });
    else if (typeof p.lat !== "number" || typeof p.lon !== "number" || Math.abs(p.lat) > 90 || Math.abs(p.lon) > 180) rejected.push({ ping: p, reason: "bad position" });
    else if (Number.isNaN(t)) rejected.push({ ping: p, reason: "bad time" });
    else if (t > Date.now() + 5 * 60_000) rejected.push({ ping: p, reason: "time is in the future" });
    else rows.push({ truck_no: truck, lat: p.lat, lon: p.lon, speed_kmph: p.speed_kmph ?? null,
                     recorded_at: new Date(t).toISOString(), source: p.source === "phone" ? "phone" : "tracker" });
  }

  // Oldest first, so "latest position" ends on the newest ping.
  rows.sort((a, b) => a.recorded_at.localeCompare(b.recorded_at));
  let saved = 0;
  for (const r of rows) {
    const { error } = await db.from("gps_pings").insert(r);
    if (error) rejected.push({ ping: r as unknown as Ping, reason: error.message }); else saved++;
  }
  return json({ saved, rejected });
});

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json" } });
