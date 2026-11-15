#!/usr/bin/env python3
"""جمع أسماء النفود والعروق والرمال في السعودية والخليج من مصادر مفتوحة:
GeoNames (CC BY 4.0)، ويكي بيانات (CC0)، OpenStreetMap (ODbL).
المخرج: GeoJSON نقاط بنوع nafud، مع تقرير إحصائي. لا تُخترع أسماء ولا مواقع."""
import csv, io, json, math, re, sys, time, zipfile, urllib.request, urllib.parse, collections

UA = {"User-Agent": "Samt-nafud-builder/1.0 (github.com/oalmuqbel-cpu/ShettaMaps2)"}
CCS = ["SA", "AE", "KW", "QA", "OM", "BH"]
AR = re.compile(r"[؀-ۿ]")
SAND_WORDS = ("نفود", "النفود", "نفد", "عرق", "عروق", "العرق", "العروق", "رملة", "رمله", "الرملة", "رمال", "الرمال",
              "الدهناء", "دهناء", "الربع الخالي", "الجافورة", "كثيب", "كثبان", "طعس", "الطعوس", "نقا", "النقا", "برقة", "عريق")
GN_CODES = {"ERG", "DUNE", "SAND", "DSRT"}

def get(url, data=None, timeout=300):
    req = urllib.request.Request(url, data=data, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()

def is_sand_name(n):
    n = n.strip()
    return any(n.startswith(w + " ") or n == w for w in SAND_WORDS)

def norm(s):
    s = re.sub(r"[ً-ٰٟـ]", "", s)
    s = s.replace("أ", "ا").replace("إ", "ا").replace("آ", "ا").replace("ة", "ه").replace("ى", "ي")
    return re.sub(r"\s+", " ", s).strip()

def dist(a, b):
    return math.hypot((a[1] - b[1]) * 111 * math.cos(math.radians(a[0])), (a[0] - b[0]) * 111)

items = []   # (name, lat, lon, source, alts, extra)

# 1) GeoNames
for cc in CCS:
    try:
        z = zipfile.ZipFile(io.BytesIO(get(f"https://download.geonames.org/export/dump/{cc}.zip")))
        rows = z.read(f"{cc}.txt").decode("utf-8").splitlines()
    except Exception as e:
        print("geonames fail", cc, e, file=sys.stderr); continue
    n_cc = 0
    for line in rows:
        f = line.split("\t")
        if len(f) < 19: continue
        name, alts, lat, lon, fclass, fcode = f[1], f[3], float(f[4]), float(f[5]), f[6], f[7]
        ar = [a for a in alts.split(",") if AR.search(a)] + ([name] if AR.search(name) else [])
        ar_sand = [a for a in ar if is_sand_name(a)]
        if fclass == "T" and fcode in GN_CODES:
            if not ar: continue   # بلا اسم عربي لا يفيد الواجهة العربية
            best = (ar_sand or ar)[0]
        elif ar_sand:
            best = ar_sand[0]
        else:
            continue
        others = [a for a in ar if a != best][:3] + [name]
        items.append((best.strip(), lat, lon, "GeoNames", others, fcode)); n_cc += 1
    print(f"GeoNames {cc}: {n_cc}", file=sys.stderr)

# 2) ويكي بيانات
countries = "wd:Q851 wd:Q878 wd:Q817 wd:Q846 wd:Q842 wd:Q398"
starts = " || ".join(f'STRSTARTS(?l, "{w}")' for w in ("نفود", "النفود", "عرق", "عروق", "رملة", "الدهناء", "الربع الخالي", "الجافورة", "رمال"))
q = f"""SELECT ?item ?l ?coord WHERE {{ VALUES ?c {{ {countries} }} ?item wdt:P17 ?c; wdt:P625 ?coord; rdfs:label ?l.
FILTER(lang(?l)="ar") FILTER({starts}) }}"""
try:
    data = json.loads(get("https://query.wikidata.org/sparql?format=json&query=" + urllib.parse.quote(q), timeout=120))
    n = 0
    for b in data["results"]["bindings"]:
        m = re.match(r"Point\(([-\d.]+) ([-\d.]+)\)", b["coord"]["value"])
        if not m: continue
        items.append((b["l"]["value"], float(m.group(2)), float(m.group(1)), "Wikidata", [], "")); n += 1
    print(f"Wikidata: {n}", file=sys.stderr)
except Exception as e:
    print("wikidata fail", e, file=sys.stderr)

# 3) OpenStreetMap
oq = """[out:json][timeout:600];
(area["ISO3166-1"~"^(SA|AE|KW|QA|OM|BH)$"][admin_level=2];)->.a;
( nwr["natural"~"^(sand|dune|desert)$"]["name"](area.a);
  nwr["name"~"^(نفود|النفود|عرق|عروق|العرق|العروق|رملة|الرملة|رمال|الدهناء|طعس|الطعوس) "](area.a);
  nwr["name:ar"~"^(نفود|النفود|عرق|عروق|العرق|العروق|رملة|الرملة|رمال|الدهناء) "](area.a); );
out center tags;"""
for ep in ("https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter",
           "https://overpass.private.coffee/api/interpreter"):
    try:
        d = json.loads(get(ep, data=urllib.parse.urlencode({"data": oq}).encode(), timeout=900))
        n = 0
        for el in d.get("elements", []):
            t = el.get("tags", {})
            nm = t.get("name:ar") or t.get("name")
            if not nm or not AR.search(nm): continue
            if not (t.get("natural") in ("sand", "dune", "desert") or is_sand_name(nm)): continue
            lat = el.get("lat") or (el.get("center") or {}).get("lat")
            lon = el.get("lon") or (el.get("center") or {}).get("lon")
            if lat is None: continue
            items.append((nm, lat, lon, "OpenStreetMap", [t.get("name")] if t.get("name") and t.get("name") != nm else [], t.get("natural", "")))
            n += 1
        print(f"OSM ({ep.split('/')[2]}): {n}", file=sys.stderr)
        break
    except Exception as e:
        print("osm fail", ep, e, file=sys.stderr); time.sleep(30)

# دمج: نفس الاسم (بعد التطبيع) ضمن ٢٥ كم = مكان واحد؛ الأولوية OSM ثم ويكي بيانات ثم GeoNames
prio = {"OpenStreetMap": 0, "Wikidata": 1, "GeoNames": 2}
items.sort(key=lambda x: prio[x[3]])
merged = []
for it in items:
    key = norm(it[0])
    dup = next((m for m in merged if m["key"] == key and dist((m["lat"], m["lon"]), (it[1], it[2])) < 25), None)
    if dup:
        dup["sources"].add(it[3]); continue
    merged.append({"key": key, "name": it[0], "lat": it[1], "lon": it[2], "sources": {it[3]},
                   "alts": [a for a in it[4] if a and a != it[0]][:3]})

feats = []
for i, m in enumerate(merged):
    src = " + ".join(sorted(m["sources"]))
    feats.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": [round(m["lon"], 5), round(m["lat"], 5)]},
                  "properties": {"id": f"nafud-{i}", "name": m["name"], "kind": "nafud", "alt_names": m["alts"],
                                 "region": "نفود وعروق", "source": src}})
json.dump({"type": "FeatureCollection", "features": feats}, open(sys.argv[1], "w", encoding="utf-8"),
          ensure_ascii=False, separators=(",", ":"))
c = collections.Counter(next(iter(sorted(m["sources"]))) for m in merged)
print(f"TOTAL {len(feats)} by first source {dict(c)}", file=sys.stderr)
first = collections.Counter(m["name"].split()[0] for m in merged)
print("FIRST WORDS", first.most_common(20), file=sys.stderr)
