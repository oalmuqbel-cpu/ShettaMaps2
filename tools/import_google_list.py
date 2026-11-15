#!/usr/bin/env python3
"""يحوّل قائمة محفوظة من Google Takeout (CSV) إلى نقاط GeoJSON لطبقة الأماكن الإضافية في سَمْت.
الاستخدام: import_google_list.py list.csv --kind water --source "مارد ماء · عبدالعزيز المفدى" --prefix mared > out.geojson
يستخرج الإحداثيات من الروابط فقط (لا يستدعي أي خدمة)، ويطبع ما لم يُحلّ إلى stderr."""
import csv, json, re, sys, argparse, hashlib, urllib.parse

PATTERNS = [
    re.compile(r"!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)"),
    re.compile(r"/search/(-?\d+\.\d+),\+?(-?\d+\.\d+)"),
    re.compile(r"[?&](?:q|query|ll|destination)=(-?\d+\.\d+),\s*(-?\d+\.\d+)"),
    re.compile(r"@(-?\d+\.\d+),(-?\d+\.\d+)"),
]

def coords(url):
    u = urllib.parse.unquote(url or "")
    for p in PATTERNS:
        m = p.search(u)
        if m:
            lat, lon = float(m.group(1)), float(m.group(2))
            if 10 <= lat <= 35 and 34 <= lon <= 60:   # الخليج والمملكة
                return lat, lon
    return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv"); ap.add_argument("--kind", default="water")
    ap.add_argument("--source", required=True); ap.add_argument("--prefix", default="ext")
    ap.add_argument("--default-name", default="مورد ماء")
    a = ap.parse_args()
    feats, missing = [], []
    with open(a.csv, encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            row = {k.strip().lower(): (v or "").strip() for k, v in row.items() if k}
            title = row.get("title") or row.get("العنوان") or ""
            url = row.get("url") or row.get("عنوان url") or ""
            note = row.get("note") or row.get("comment") or ""
            c = coords(url)
            if not c:
                missing.append(title or url); continue
            lat, lon = c
            fid = a.prefix + "-" + hashlib.sha1(f"{lat:.5f},{lon:.5f}".encode()).hexdigest()[:10]
            props = {"id": fid, "name": title or a.default_name, "kind": a.kind, "region": a.source, "source": a.source}
            if note: props["alt_names"] = [note[:80]]
            feats.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": [round(lon, 6), round(lat, 6)]},
                          "properties": props})
    json.dump({"type": "FeatureCollection", "features": feats}, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    print(f"converted {len(feats)}, unresolved {len(missing)}", file=sys.stderr)
    for m in missing[:50]: print("  unresolved:", m, file=sys.stderr)

if __name__ == "__main__":
    main()
