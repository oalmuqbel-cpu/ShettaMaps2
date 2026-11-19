#!/usr/bin/env python3
"""
طبقة «مدن وقرى» و«خدمات» لتطبيق سَمْت، من مصادر مفتوحة يجوز تخزينها وعرضها دون إنترنت:
- OpenStreetMap (ODbL): المدن والقرى والهجر والأحياء والمزارع، والمستشفيات والمراكز الصحية والشرطة والدفاع المدني.
- GeoNames (CC BY 4.0): الأماكن المأهولة (P) والمستشفيات ومراكز الشرطة (S.HSP, S.PP) مع أسمائها العربية إن وُجدت.
تُدمج الأسماء المتكررة (نفس الاسم بعد التطبيع ضمن ٢ كم) ويُفضَّل الاسم العربي من OSM.
الاستخدام: build_towns.py out.geojson osm/*.json -- geonames/*.txt
"""
import json, sys, math, re, unicodedata

ARABIC = re.compile(r"[؀-ۿ]")

def norm(s):
    s = unicodedata.normalize("NFKD", s)
    s = re.sub(r"[ً-ٰٟ]", "", s)          # التشكيل
    s = s.replace("أ", "ا").replace("إ", "ا").replace("آ", "ا").replace("ة", "ه").replace("ى", "ي")
    s = re.sub(r"^ال", "", s.strip())
    return re.sub(r"\s+", " ", s).lower()

def km(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * 6371 * math.asin(math.sqrt(h))

PLACE_AR = {"city": "مدينة", "town": "بلدة", "village": "قرية", "hamlet": "هجرة", "suburb": "حي", "neighbourhood": "حي",
            "quarter": "حي", "farm": "مزرعة"}
SERVICE_AR = {"hospital": "مستشفى", "clinic": "مركز صحي", "police": "شرطة", "fire_station": "دفاع مدني"}

def from_osm(path):
    out = []
    for el in json.load(open(path, encoding="utf-8")).get("elements", []):
        t = el.get("tags", {})
        lat = el.get("lat") or (el.get("center") or {}).get("lat")
        lon = el.get("lon") or (el.get("center") or {}).get("lon")
        if lat is None or lon is None:
            continue
        if "place" in t:
            kind, label = "town", PLACE_AR.get(t["place"], "")
        else:
            a = t.get("amenity") or ("hospital" if t.get("healthcare") == "hospital" else "")
            kind, label = "service", SERVICE_AR.get(a, "خدمة")
        name = t.get("name:ar") or t.get("name") or (label if kind == "service" else None)
        if not name:
            continue
        alts = sorted({v for k, v in t.items() if k in ("name", "name:en", "alt_name", "old_name") and v and v != name})
        out.append({"name": name, "alt": alts, "kind": kind, "lat": round(lat, 5), "lon": round(lon, 5),
                    "region": label, "src": "OpenStreetMap", "rank": 0})
    return out

def from_geonames(path):
    out = []
    for line in open(path, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if len(f) < 15:
            continue
        cls, code = f[6], f[7]
        if cls == "P":
            kind, label = "town", {"PPLC": "عاصمة", "PPLA": "مدينة", "PPLA2": "مدينة", "PPL": "قرية"}.get(code, "قرية")
        elif cls == "S" and code in ("HSP", "HSPC", "HSPD", "CTRM"):
            kind, label = "service", "مستشفى"
        elif cls == "S" and code == "PP":
            kind, label = "service", "شرطة"
        else:
            continue
        alts = [a for a in f[3].split(",") if a]
        ar = next((a for a in alts if ARABIC.search(a)), None)
        name = ar or f[1]
        others = sorted({a for a in [f[1], f[2]] + alts[:6] if a and a != name})[:6]
        out.append({"name": name, "alt": others, "kind": kind, "lat": round(float(f[4]), 5), "lon": round(float(f[5]), 5),
                    "region": label, "src": "GeoNames", "rank": 1})
    return out

def main():
    dst = sys.argv[1]
    args = sys.argv[2:]
    sep = args.index("--") if "--" in args else len(args)
    items = []
    for p in args[:sep]:
        items += from_osm(p)
    for p in args[sep + 1:]:
        items += from_geonames(p)
    # الأماكن السعودية والخليجية فقط
    items = [i for i in items if 12 <= i["lat"] <= 33 and 34 <= i["lon"] <= 60]
    # إزالة التكرار: نفس الاسم المطبع (أو أحد أسمائه البديلة) ضمن ٢ كم، مع تفضيل OSM العربي
    items.sort(key=lambda i: (i["rank"], 0 if ARABIC.search(i["name"]) else 1))
    grid, kept = {}, []
    for i in items:
        keys = {norm(i["name"])} | {norm(a) for a in i["alt"]}
        cell = (int(i["lat"] * 20), int(i["lon"] * 20))
        dup = False
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for j in grid.get((cell[0] + dx, cell[1] + dy), []):
                    if keys & j["_keys"] and km((i["lat"], i["lon"]), (j["lat"], j["lon"])) < 2:
                        dup = True
                        if i["src"] not in j["src"]:
                            j["src"] += " + " + i["src"]
                        break
                if dup: break
            if dup: break
        if dup:
            continue
        i["_keys"] = keys
        grid.setdefault(cell, []).append(i)
        kept.append(i)
    feats = []
    for n, i in enumerate(kept):
        props = {"id": f"t{n}", "name": i["name"], "kind": i["kind"], "region": i["region"], "source": i["src"]}
        if i["alt"]:
            props["alt_names"] = i["alt"][:5]
        feats.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": [i["lon"], i["lat"]]}, "properties": props})
    out = {"type": "FeatureCollection",
           "attribution": "© OpenStreetMap contributors (ODbL), GeoNames (CC BY 4.0)",
           "features": feats}
    json.dump(out, open(dst, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
    from collections import Counter
    print("features", len(feats), Counter(f["properties"]["kind"] for f in feats), Counter(i["src"] for i in kept).most_common(4))

if __name__ == "__main__":
    main()
