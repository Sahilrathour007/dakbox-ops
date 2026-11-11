#!/usr/bin/env python3
"""
Import official NHAI toll plazas (location + fee per vehicle class) into Dakbox.

Source: NHAI RajMargyatra, https://rajmargyatra.nhai.gov.in (NHAI's official highway information service)
  - getTollplazaName     : every toll plaza and its id
  - getTollplazaDetails  : one plaza's latitude/longitude, state, NH and fees for each vehicle class
Matched against: NHAI "National Highway (NH) Fee Plazas" list (data/nh_fee_plazas.csv)

Run it on a normal home or office connection in India (NHAI blocks most cloud servers).
Python 3.8+, nothing to install. Windows: use "python" instead of "python3".

  python tools/import_nhai_tolls.py --upload you@example.com   # download from NHAI and upload to Supabase
  python tools/import_nhai_tolls.py                            # only write data/toll_plazas_import.sql + .csv
"""
import argparse, csv, difflib, getpass, gzip, json, os, re, sys, time, urllib.request, zlib
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
API = "https://rajmargyatra.nhai.gov.in/nhai/api"
SITE = "https://rajmargyatra.nhai.gov.in"
HEADERS = {
    "Content-Type": "application/json", "Accept": "application/json, text/plain, */*",
    "Accept-Language": "en-IN,en;q=0.9", "Accept-Encoding": "gzip, deflate",
    "Origin": SITE, "Referer": SITE + "/ataglance",
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
}
# NHAI field (single journey fee, Rs) -> our column
RATE_FIELDS = {
    "rate_car": "CarRate_single",
    "rate_lcv": "LCVRate_single",
    "rate_bus_truck": "BusRate_single",           # bus / truck (2-axle)
    "rate_upto_3_axle": "MultiAxleRate_single",   # up to 3-axle commercial vehicle
    "rate_axle_4_6": "FourToSixExel_Single",
    "rate_hcm_eme": "HCM_EME_Single",
    "rate_axle_7_plus": "SevenOrmoreExel_Single",
}
COLS = ["id", "name", "netc_code", "pdf_s_no", "state", "district", "section", "nh", "lat", "lon"] + \
       list(RATE_FIELDS) + ["fee_effective_date", "source_url"]


def post(path, body, tries=4):
    data = json.dumps(body).encode()
    for i in range(tries):
        try:
            req = urllib.request.Request(f"{API}/{path}", data=data, method="POST", headers=HEADERS)
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
                enc = r.headers.get("Content-Encoding", "")
                if enc == "gzip": raw = gzip.decompress(raw)
                elif enc == "deflate": raw = zlib.decompress(raw)
                return json.loads(raw.decode("utf-8", "replace"))
        except Exception as e:
            if i == tries - 1: raise
            time.sleep(2 * (i + 1))


def num(v):
    if v is None: return None
    s = str(v).replace(",", "").strip()
    try:
        x = float(s)
        return x if x >= 0 else None
    except ValueError:
        return None


def norm(name):
    n = (name or "").lower()
    n = re.sub(r"\(.*?\)", " ", n)
    n = re.sub(r"\b(toll|plaza|fee|nh|old|new|check|bypass|tp|phase)\b", " ", n)
    n = re.sub(r"[^a-z0-9]+", " ", n)
    return re.sub(r"\s+", " ", n).strip()


def norm_state(s):
    return re.sub(r"[^a-z]", "", (s or "").lower())


def to_row(d):
    """One NHAI getTollplazaDetails record -> our toll_plazas row (without the PDF columns)."""
    try:
        pid = int(d.get("tollplaza_id")); lat = float(d.get("latitude")); lon = float(d.get("longitude"))
    except (TypeError, ValueError):
        return None
    if not (6 <= lat <= 37 and 68 <= lon <= 98):
        return None
    row = {"id": pid, "name": (d.get("tollplaza_name") or "").strip(), "lat": lat, "lon": lon,
           "state": d.get("state_name"), "nh": d.get("nh_no"), "fee_effective_date": d.get("DtEffectiveRates"),
           "source_url": f"{SITE} (getTollplazaDetails, tollplaza_id={pid})",
           "netc_code": None, "pdf_s_no": None, "district": None, "section": None}
    for col, field in RATE_FIELDS.items():
        row[col] = num(d.get(field))
    return row


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--upload", metavar="EMAIL", help="upload to Supabase, signing in with this staff email")
    ap.add_argument("--raw", metavar="FILE", help="use saved getTollplazaDetails records (a JSON list) instead of downloading")
    a = ap.parse_args()

    pdf_rows = list(csv.DictReader(open(os.path.join(ROOT, "data", "nh_fee_plazas.csv"), encoding="utf-8")))
    by_name = {}
    for r in pdf_rows: by_name.setdefault(norm(r["name"]), []).append(r)

    if a.raw:
        details = json.load(open(a.raw, encoding="utf-8"))
    else:
        print("1/3 Getting the list of toll plazas from NHAI RajMargyatra ...")
        try:
            lst = post("getTollplazaName", {})
        except Exception as e:
            sys.exit(f"Could not reach NHAI RajMargyatra ({API}): {e}\n"
                     f"Check that https://rajmargyatra.nhai.gov.in opens in your browser, then try again.")
        plazas = lst.get("payload") or []
        if lst.get("resultCode") != 200 or not plazas:
            sys.exit(f"NHAI did not return a plaza list: {str(lst)[:300]}")
        print(f"    {len(plazas)} plazas listed.")
        print("2/3 Getting location and fees for each plaza (a few minutes) ...")
        details, failed, done = [], [], [0]

        def one(p):
            try:
                r = post("getTollplazaDetails", {"tollplaza_id": p.get("tollplaza_id")})
                if r.get("resultCode") == 200 and r.get("payload"):
                    return r["payload"][0]
            except Exception:
                pass
            failed.append(p.get("tollplaza_id")); return None

        with ThreadPoolExecutor(max_workers=6) as ex:
            for d in ex.map(one, plazas):
                done[0] += 1
                if d: details.append(d)
                if done[0] % 100 == 0: print(f"    {done[0]} / {len(plazas)}")
        print(f"    details for {len(details)} plazas, {len(failed)} failed")
        with open(os.path.join(ROOT, "data", "nhai_raw_details.json"), "w", encoding="utf-8") as f:
            json.dump(details, f)

    out, matched = [], set()
    for d in details:
        row = to_row(d)
        if not row: continue
        cands = by_name.get(norm(row["name"]), [])
        if len(cands) > 1:   # same name in several states: use the state too
            cands = [c for c in cands if norm_state(c["state"]) == norm_state(row["state"])] or cands
        pdf = cands[0] if len(cands) == 1 else None
        if not pdf:   # spelling differs (e.g. Kherki / Khedki): closest name in the same state, if very close
            same_state = [r for r in pdf_rows if norm_state(r["state"]) == norm_state(row["state"]) and r["s_no"] not in matched]
            best = max(same_state, key=lambda r: difflib.SequenceMatcher(None, norm(r["name"]), norm(row["name"])).ratio(), default=None)
            if best and difflib.SequenceMatcher(None, norm(best["name"]), norm(row["name"])).ratio() >= 0.85:
                pdf = best
        if pdf:
            matched.add(pdf["s_no"])
            row.update({"netc_code": pdf["netc_code"] or None, "pdf_s_no": int(pdf["s_no"]),
                        "district": pdf["district"], "section": pdf["section"], "nh": row["nh"] or pdf["nh"]})
        out.append(row)
    if not out: sys.exit("No usable plaza records (no coordinates). Nothing written.")

    def lit(v):
        if v is None or v == "": return "null"
        if isinstance(v, (int, float)): return repr(v)
        return "'" + str(v).replace("'", "''") + "'"
    sql_path = os.path.join(ROOT, "data", "toll_plazas_import.sql")
    with open(sql_path, "w", encoding="utf-8") as f:
        f.write("-- Official NHAI toll plazas (RajMargyatra), generated by tools/import_nhai_tolls.py\n")
        for i in range(0, len(out), 200):
            chunk = out[i:i + 200]
            f.write(f"insert into public.toll_plazas ({', '.join(COLS)}) values\n")
            f.write(",\n".join("(" + ", ".join(lit(r[c]) for c in COLS) + ")" for r in chunk))
            f.write("\non conflict (id) do update set " + ", ".join(f"{c} = excluded.{c}" for c in COLS if c != "id") + ", fetched_at = now();\n")
    with open(os.path.join(ROOT, "data", "toll_plazas_import.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=COLS); w.writeheader(); w.writerows(out)
    unmatched = [r for r in pdf_rows if r["s_no"] not in matched]
    with open(os.path.join(ROOT, "data", "toll_plazas_unmatched.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(pdf_rows[0].keys())); w.writeheader(); w.writerows(unmatched)

    no_truck_rate = sum(1 for r in out if r["rate_upto_3_axle"] is None)
    print(f"3/3 Plazas with location: {len(out)}")
    print(f"    Without an 'up to 3-axle' fee: {no_truck_rate}")
    print(f"    Matched to your NHAI fee plaza list: {len(matched)} of {len(pdf_rows)} (unmatched: data/toll_plazas_unmatched.csv)")
    print(f"    Wrote {sql_path}")

    if a.upload:
        cfg = open(os.path.join(ROOT, "config.js"), encoding="utf-8").read()
        url = re.search(r'SUPABASE_URL:\s*"([^"]+)"', cfg).group(1).rstrip("/")
        key = re.search(r'SUPABASE_ANON_KEY:\s*"([^"]+)"', cfg).group(1)
        pw = getpass.getpass(f"Supabase password for {a.upload} (typing is hidden): ")
        try:
            tok = json.loads(urllib.request.urlopen(urllib.request.Request(
                url + "/auth/v1/token?grant_type=password", data=json.dumps({"email": a.upload, "password": pw}).encode(),
                headers={"apikey": key, "Content-Type": "application/json"}), timeout=60).read())["access_token"]
        except Exception as e:
            sys.exit(f"Sign-in failed ({e}). Check the email and password, then run again. "
                     f"Or paste {sql_path} into the Supabase SQL Editor instead.")
        for i in range(0, len(out), 200):
            try:
                urllib.request.urlopen(urllib.request.Request(
                    url + "/rest/v1/toll_plazas?on_conflict=id", data=json.dumps(out[i:i + 200]).encode(), method="POST",
                    headers={"apikey": key, "Authorization": "Bearer " + tok, "Content-Type": "application/json",
                             "Prefer": "resolution=merge-duplicates,return=minimal"}), timeout=120).read()
            except urllib.error.HTTPError as e:
                sys.exit(f"Upload failed: {e.code} {e.read().decode()[:300]}\n"
                         f"Did you run supabase/migration_006_tolls_simulation.sql first?")
            print(f"    Uploaded {min(i + 200, len(out))} / {len(out)}")
        print("Done. Official NHAI toll plazas are in Supabase.")


if __name__ == "__main__":
    main()
