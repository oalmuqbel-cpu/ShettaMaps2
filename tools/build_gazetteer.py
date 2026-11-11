#!/usr/bin/env python3
"""
يحوّل ناتج Overpass API (بيانات OpenStreetMap) إلى قاعدة الأماكن المحلية لتطبيق خرائط شتة 2.

لا تحتوي هذه الأداة على أي أسماء أو إحداثيات؛ كل البيانات تأتي من الملف الذي تنزله أنت من OSM.
البيانات مرخصة بموجب ODbL وتتطلب الإسناد: © OpenStreetMap contributors

الاستخدام:
  1) نفّذ الاستعلام الموجود في docs/gazetteer-overpass.txt على https://overpass-turbo.eu
     ثم Export > raw OSM data (JSON) واحفظه باسم osm.json
  2) python3 tools/build_gazetteer.py osm.json gazetteer.geojson
  3) استورد gazetteer.geojson من شاشة البحث في التطبيق، أو ضعه مكان الملف المضمن في Resources.
"""
import json, sys

def kind_for(tags: dict, name: str) -> str:
    n = name.strip()
    if n.startswith(("روضة", "روضه", "فيضة", "فيضه", "الفيضة", "الروضة")):
        return "rawdah"
    if n.startswith(("شعيب", "الشعيب")):
        return "shaib"
    if n.startswith(("وادي", "الوادي")) or tags.get("waterway") == "wadi" or tags.get("natural") == "valley":
        return "valley"
    if tags.get("natural") in ("peak", "hill", "ridge", "volcano", "cliff", "rock") or n.startswith(("جبل", "جبال")):
        return "mountain"
    if tags.get("tourism") in ("camp_site", "picnic_site") or tags.get("leisure") == "picnic_table":
        return "camp"
    if tags.get("natural") == "spring" or tags.get("man_made") in ("water_well", "water_tower") or tags.get("amenity") == "drinking_water":
        return "water"
    return "landmark"

def center(el):
    if el.get("type") == "node":
        return el.get("lat"), el.get("lon")
    c = el.get("center")
    if c:
        return c.get("lat"), c.get("lon")
    return None, None

def main(src, dst):
    data = json.load(open(src, encoding="utf-8"))
    features, seen = [], set()
    for el in data.get("elements", []):
        tags = el.get("tags", {})
        name = tags.get("name:ar") or tags.get("name")
        if not name:
            continue
        lat, lon = center(el)
        if lat is None or lon is None:
            continue
        key = (name, round(lat, 3), round(lon, 3))
        if key in seen:
            continue
        seen.add(key)
        alts = [v for k, v in tags.items() if k in ("name", "name:en", "alt_name", "old_name") and v != name]
        features.append({
            "type": "Feature",
            "geometry": {"type": "Point", "coordinates": [lon, lat]},
            "properties": {
                "id": f"osm-{el['type']}-{el['id']}",
                "name": name,
                "alt_names": alts,
                "kind": kind_for(tags, name),
                "source": "OpenStreetMap (ODbL)"
            }
        })
    json.dump({"type": "FeatureCollection", "attribution": "© OpenStreetMap contributors", "features": features},
              open(dst, "w", encoding="utf-8"), ensure_ascii=False)
    print(f"تم إنشاء {len(features)} مكان في {dst}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(1)
    main(sys.argv[1], sys.argv[2])
