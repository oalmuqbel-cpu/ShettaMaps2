#!/usr/bin/env python3
"""
طبقة «المحميات» لتطبيق سَمْت من OpenStreetMap (ODbL):
boundary=protected_area / boundary=national_park / leisure=nature_reserve داخل السعودية.
تُبسَّط الحدود للعرض دون إنترنت، ويُحفظ مع كل محمية مصدرها (رابط عنصر OSM) وما فيها من بيانات الجهة والموقع.
لا تُخترع حدود ولا أنظمة: ما ليس في المصدر لا يُضاف.
الاستخدام: build_reserves.py out.geojson summary.md preview.png in.geojsonseq
"""
import json, sys
from shapely.geometry import shape, mapping, box
from shapely.ops import unary_union

out, summary, preview, src = sys.argv[1:5]
countries_src = sys.argv[5] if len(sys.argv) > 5 else None
REGION = box(34.4, 16.0, 60.0, 32.2)   # السعودية ودول الخليج
# عناصر ليست محميات طبيعية (حدود دينية أو منشآت أو مناطق مغلقة بلا اسم)
EXCLUDE = ("حدود الحرم", "منطقة مغلقة", "Qatar Steel", "KISR", "مدائن صالح", "الأثري", "مقابر", "Safari")

# حدود الدول لمعرفة دولة كل محمية
COUNTRIES = []
if countries_src:
    for line in open(countries_src, encoding="utf-8"):
        line = line.strip().lstrip("\x1e")
        if not line:
            continue
        f = json.loads(line)
        t = f.get("properties") or {}
        code = t.get("ISO3166-1") or t.get("ISO3166-1:alpha2")
        if t.get("admin_level") == "2" and code and f.get("geometry"):
            try:
                COUNTRIES.append((code, shape(f["geometry"]).buffer(0)))
            except Exception:
                pass

def country(geom):
    best, area = None, 0
    for code, poly in COUNTRIES:
        try:
            a = geom.intersection(poly).area
        except Exception:
            continue
        if a > area:
            best, area = code, a
    return best

def osm_url(t):
    # osmium export -a type,id: نوع العنصر الأصلي ورقمه
    typ, oid = t.get("@type"), t.get("@id")
    if typ in ("way", "relation") and oid:
        return f"https://www.openstreetmap.org/{typ}/{oid}"
    return None

def kind(t):
    name = " ".join(t.get(k, "") for k in ("name", "name:ar", "name:en", "official_name"))
    low = name.lower()
    if "ملكية" in name or "royal" in low:
        return "royal"
    if t.get("boundary") == "national_park" or "متنزه" in name or "national park" in low:
        return "park"
    return "wildlife"

feats, rows = [], []
for line in open(src, encoding="utf-8"):
    line = line.strip().lstrip("\x1e")
    if not line:
        continue
    f = json.loads(line)
    t = f.get("properties") or {}
    g = f.get("geometry")
    if not g or g["type"] not in ("Polygon", "MultiPolygon"):
        continue
    try:
        geom = shape(g)
        if not geom.is_valid:
            geom = geom.buffer(0)
    except Exception:
        continue
    if geom.is_empty or not geom.intersects(REGION):
        continue
    # نستبعد المساحات الصغيرة جدًا (حدائق أحياء مثلًا) أقل من ~1 كم²
    area_km2 = geom.area * 111 * 111 * 0.9
    if area_km2 < 1:
        continue
    name_ar = t.get("name:ar") or (t.get("name") if any("؀" <= c <= "ۿ" for c in t.get("name", "")) else None)
    name = name_ar or t.get("name") or t.get("name:en")
    if not name or any(x in name for x in EXCLUDE):
        continue
    simp = geom.simplify(0.002, preserve_topology=True)
    props = {
        "name": name,
        "name_en": t.get("name:en"),
        "kind": kind(t),
        "operator": t.get("operator:ar") or t.get("operator"),
        "website": t.get("website") or t.get("contact:website") or t.get("url"),
        "wikidata": t.get("wikidata"),
        "protect_class": t.get("protect_class"),
        "area_km2": round(area_km2),
        "osm": osm_url(t),
        "country": country(geom),
    }
    feats.append({"type": "Feature", "geometry": mapping(simp), "properties": props})
    rows.append(props)

# إزالة التكرار (نفس الاسم): نبقي الأكبر
best = {}
for f in feats:
    k = f["properties"]["name"]
    if k not in best or f["properties"]["area_km2"] > best[k]["properties"]["area_km2"]:
        best[k] = f
feats = sorted(best.values(), key=lambda f: -f["properties"]["area_km2"])
for f in feats:
    f["geometry"] = json.loads(json.dumps(f["geometry"]), parse_float=lambda x: round(float(x), 5))

json.dump({"type": "FeatureCollection",
           "attribution": "© OpenStreetMap contributors (ODbL)",
           "features": feats}, open(out, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))

with open(summary, "w", encoding="utf-8") as s:
    s.write(f"# المحميات في OpenStreetMap داخل السعودية ({len(feats)})\n\n")
    s.write("| # | الاسم | النوع | الدولة | المساحة كم² | الجهة | الموقع | المصدر |\n|---|---|---|---|---|---|---|---|\n")
    for i, f in enumerate(feats, 1):
        p = f["properties"]
        s.write(f"| {i} | {p['name']} | {p['kind']} | {p['country'] or ''} | {p['area_km2']} | {p['operator'] or ''} | {p['website'] or ''} | {p['osm']} |\n")
print(len(feats), "reserves")

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
colors = {"royal": "#8a5a2b", "wildlife": "#2e7d32", "park": "#1565c0"}
fig, ax = plt.subplots(figsize=(10, 9))
for f in feats:
    g = shape(f["geometry"])
    polys = [g] if g.geom_type == "Polygon" else list(g.geoms)
    for p in polys:
        x, y = p.exterior.xy
        ax.fill(x, y, alpha=0.35, color=colors[f["properties"]["kind"]])
        ax.plot(x, y, lw=0.6, color=colors[f["properties"]["kind"]])
ax.set_xlim(34, 60); ax.set_ylim(16, 33); ax.set_aspect(1.05)
ax.set_title(f"Protected areas in OSM within Saudi Arabia: {len(feats)} (brown=royal, green=wildlife, blue=park)")
plt.savefig(preview, dpi=110, bbox_inches="tight")
