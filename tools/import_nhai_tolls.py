#!/usr/bin/env python3
"""
Import official NHAI toll plazas (location + fee per vehicle class) into Dakbox.

Source: NHAI Toll Information System, https://tis.nhai.gov.in
  - every plaza with its latitude/longitude and fee table (map service)
Matched against: NHAI "National Highway (NH) Fee Plazas" list (data/nh_fee_plazas.csv)

Run it on a computer in India (NHAI blocks most servers abroad). Python 3.8+, nothing to install.

  python3 tools/import_nhai_tolls.py                      # writes data/toll_plazas_import.sql + .csv
  python3 tools/import_nhai_tolls.py --upload you@x.com   # also uploads to Supabase (asks for your password)

If you do not upload, open Supabase -> SQL Editor, paste data/toll_plazas_import.sql and Run.
"""
import argparse, csv, getpass, html, http.cookiejar, json, os, re, sys, urllib.request
from html.parser import HTMLParser

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TIS = "https://tis.nhai.gov.in"
MAP_SERVICE = TIS + "/TollPlazaService.asmx/GetTollPlazaInfoForMapOnPC"
DETAIL_PAGE = TIS + "/TollInformation.aspx?TollPlazaID={}"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

# NHAI fee table rows -> our columns (matched on the row label, case-insensitive)
CLASSES = [
    ("rate_car",         r"car|jeep|van"),
    ("rate_lcv",         r"\blcv\b|light commercial"),
    ("rate_bus_truck",   r"bus|truck"),
    ("rate_upto_3_axle", r"up\s*to\s*3|3\s*axle|three axle"),
    ("rate_axle_4_6",    r"4\s*(to|-)\s*6|four to six"),
    ("rate_hcm_eme",     r"hcm|eme|earth|construction machin"),
    ("rate_axle_7_plus", r"7\s*or\s*more|7\s*\+|seven"),
]


class Tables(HTMLParser):
    """Collect every <table> as a list of rows of cell texts."""
    def __init__(self):
        super().__init__(); self.tables = []; self._row = None; self._cell = None; self.text = []
    def handle_starttag(self, tag, attrs):
        if tag == "table": self.tables.append([])
        elif tag == "tr" and self.tables: self._row = []
        elif tag in ("td", "th") and self._row is not None: self._cell = []
    def handle_endtag(self, tag):
        if tag in ("td", "th") and self._cell is not None and self._row is not None:
            self._row.append(re.sub(r"\s+", " ", "".join(self._cell)).strip()); self._cell = None
        elif tag == "tr" and self._row is not None and self.tables:
            if self._row: self.tables[-1].append(self._row)
            self._row = None
    def handle_data(self, data):
        self.text.append(data)
        if self._cell is not None: self._cell.append(data)


def parse_fees(page_html):
    """Return ({column: single-journey fee}, fee effective date) from an NHAI fee table."""
    p = Tables(); p.feed(page_html or "")
    fees = {}
    for table in p.tables:
        for row in table:
            if len(row) < 2: continue
            label = row[0].lower()
            nums = [float(x.replace(",", "")) for x in row[1:] if re.fullmatch(r"[\d,]+(\.\d+)?", x.replace(" ", ""))]
            if not nums: continue
            for col, pattern in CLASSES:
                # "Bus/Truck" must not swallow "LCV" or axle rows; check the specific classes first
                if col in fees: continue
                if re.search(pattern, label):
                    if col == "rate_bus_truck" and re.search(r"axle|lcv|light", label): continue
                    fees[col] = nums[0]          # first number = single journey
                    break
    text = re.sub(r"\s+", " ", " ".join(p.text))
    m = re.search(r"Fee Effective Date\s*:?\s*([0-9A-Za-z/\- ,]+?\d{4})", text)
    return fees, (m.group(1).strip() if m else None)


def norm(name):
    n = name.lower()
    n = re.sub(r"\(.*?\)", " ", n)
    n = re.sub(r"\b(toll|plaza|fee|nh|old|new|check|bypass|tp)\b", " ", n)
    n = re.sub(r"[^a-z0-9]+", " ", n)
    return re.sub(r"\s+", " ", n).strip()


def fetch_map(opener):
    # visit the map page first so the server sets its session cookie
    for page in ("/", "/map1.htm"):
        try: opener.open(urllib.request.Request(TIS + page, headers={"User-Agent": UA}), timeout=60).read()
        except Exception: pass
    req = urllib.request.Request(MAP_SERVICE, data=b"", method="POST", headers={
        "User-Agent": UA, "Content-Type": "application/json; charset=utf-8",
        "Accept": "application/json, text/javascript, */*; q=0.01", "X-Requested-With": "XMLHttpRequest",
        "Origin": TIS, "Referer": TIS + "/map1.htm"})
    body = opener.open(req, timeout=120).read().decode("utf-8", "replace")
    data = json.loads(body)
    return data.get("d", data) if isinstance(data, dict) else data


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--upload", metavar="EMAIL", help="upload to Supabase, signing in with this staff email")
    ap.add_argument("--raw", metavar="FILE", help="use a saved copy of the NHAI map service response instead of downloading")
    ap.add_argument("--details", action="store_true", help="also open each plaza's NHAI page when the map has no fee table")
    a = ap.parse_args()

    pdf_rows = list(csv.DictReader(open(os.path.join(ROOT, "data", "nh_fee_plazas.csv"), encoding="utf-8")))
    by_name = {}
    for r in pdf_rows: by_name.setdefault(norm(r["name"]), []).append(r)

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    if a.raw:
        data = json.load(open(a.raw, encoding="utf-8")); items = data.get("d", data) if isinstance(data, dict) else data
    else:
        print("Downloading plazas from NHAI Toll Information System ...")
        try: items = fetch_map(opener)
        except Exception as e:
            sys.exit(f"Could not read {MAP_SERVICE}: {e}\nRun this on a computer in India, or save the response "
                     f"from your browser and pass it with --raw.")
    print(f"NHAI returned {len(items)} plazas.")

    out, no_fee, matched_pdf = [], [], set()
    for it in items:
        try:
            pid = int(it.get("TollPlazaID")); lat = float(it.get("latitude")); lon = float(it.get("longitude"))
        except (TypeError, ValueError):
            continue
        name = html.unescape((it.get("TollName") or "").strip())
        fees, eff = parse_fees(it.get("HtmlPopup") or "")
        if not fees and a.details:
            try:
                page = opener.open(urllib.request.Request(DETAIL_PAGE.format(pid), headers={"User-Agent": UA}), timeout=60).read().decode("utf-8", "replace")
                fees, eff2 = parse_fees(page); eff = eff or eff2
            except Exception: pass
        if not fees: no_fee.append(name)
        cands = by_name.get(norm(name), [])
        pdf = cands[0] if len(cands) == 1 else None
        if pdf: matched_pdf.add(pdf["s_no"])
        row = {"id": pid, "name": name, "lat": lat, "lon": lon, "fee_effective_date": eff,
               "source_url": DETAIL_PAGE.format(pid),
               "netc_code": (pdf or {}).get("netc_code") or None, "pdf_s_no": int(pdf["s_no"]) if pdf else None,
               "state": (pdf or {}).get("state"), "district": (pdf or {}).get("district"),
               "section": (pdf or {}).get("section"), "nh": (pdf or {}).get("nh")}
        for col, _ in CLASSES: row[col] = fees.get(col)
        out.append(row)

    cols = ["id", "name", "netc_code", "pdf_s_no", "state", "district", "section", "nh", "lat", "lon"] + \
           [c for c, _ in CLASSES] + ["fee_effective_date", "source_url"]
    os.makedirs(os.path.join(ROOT, "data"), exist_ok=True)
    csv_path = os.path.join(ROOT, "data", "toll_plazas_import.csv")
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=cols); w.writeheader(); w.writerows(out)

    def lit(v):
        if v is None or v == "": return "null"
        if isinstance(v, (int, float)): return repr(v)
        return "'" + str(v).replace("'", "''") + "'"
    sql_path = os.path.join(ROOT, "data", "toll_plazas_import.sql")
    with open(sql_path, "w", encoding="utf-8") as f:
        f.write("-- Official NHAI toll plazas, generated by tools/import_nhai_tolls.py\n")
        for i in range(0, len(out), 200):
            chunk = out[i:i + 200]
            f.write(f"insert into public.toll_plazas ({', '.join(cols)}) values\n")
            f.write(",\n".join("(" + ", ".join(lit(r[c]) for c in cols) + ")" for r in chunk))
            f.write("\non conflict (id) do update set " + ", ".join(f"{c} = excluded.{c}" for c in cols if c != "id") + ", fetched_at = now();\n")

    unmatched = [r for r in pdf_rows if r["s_no"] not in matched_pdf]
    with open(os.path.join(ROOT, "data", "toll_plazas_unmatched.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(pdf_rows[0].keys())); w.writeheader(); w.writerows(unmatched)

    print(f"Plazas with location: {len(out)}")
    print(f"Plazas with an NHAI fee table: {len(out) - len(no_fee)}  (no fee table: {len(no_fee)}; try --details)")
    print(f"Matched to your NHAI fee plaza list: {len(matched_pdf)} of {len(pdf_rows)}  (unmatched: data/toll_plazas_unmatched.csv)")
    print(f"Wrote {sql_path}\nWrote {csv_path}")

    if a.upload:
        cfg = open(os.path.join(ROOT, "config.js"), encoding="utf-8").read()
        url = re.search(r'SUPABASE_URL:\s*"([^"]+)"', cfg).group(1).rstrip("/")
        key = re.search(r'SUPABASE_ANON_KEY:\s*"([^"]+)"', cfg).group(1)
        pw = getpass.getpass(f"Supabase password for {a.upload}: ")
        tok = json.loads(urllib.request.urlopen(urllib.request.Request(
            url + "/auth/v1/token?grant_type=password", data=json.dumps({"email": a.upload, "password": pw}).encode(),
            headers={"apikey": key, "Content-Type": "application/json"}), timeout=60).read())["access_token"]
        for i in range(0, len(out), 200):
            chunk = [{k: v for k, v in r.items()} for r in out[i:i + 200]]
            urllib.request.urlopen(urllib.request.Request(
                url + "/rest/v1/toll_plazas?on_conflict=id", data=json.dumps(chunk).encode(), method="POST",
                headers={"apikey": key, "Authorization": "Bearer " + tok, "Content-Type": "application/json",
                         "Prefer": "resolution=merge-duplicates,return=minimal"}), timeout=120).read()
            print(f"Uploaded {min(i + 200, len(out))} / {len(out)}")
        print("Done. Toll plazas are in Supabase.")


if __name__ == "__main__":
    main()
