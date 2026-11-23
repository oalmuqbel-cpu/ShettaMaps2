#!/usr/bin/env python3
"""
شبكة طرق القيادة لسَمْت من OpenStreetMap (ODbL)، لحساب الطريق داخل الجوال دون إنترنت.
الطرق المشمولة: السريعة والرئيسية والفرعية والسكنية (مع وصلاتها). لا تشمل الطرق الترابية (لها الخط المباشر).
المخرجات لكل منطقة ملف ثنائي samtroute (Little Endian):
  رأس: "SAMTRT1\\0", uint32 version, N vertices, M edges(info), D directed, G geometry points, S names bytes, grid...
  vertices: N × (int32 lat×1e6, int32 lon×1e6)
  firstOut: (N+1) × uint32               — بداية حواف كل رأس (CSR)
  directed: D × (uint32 target, uint32 info | 0x80000000 إذا كانت بعكس اتجاه الرسم)
  info: M × (float32 length_m, uint8 speed_kmh, uint8 class, uint8 flags, uint8 pad, uint32 name_off, uint32 geom_start, uint32 geom_count)
  geometry: G × (int32 lat×1e6, int32 lon×1e6)  — النقاط الوسطية للحافة باتجاه الرسم
  names: S bytes (UTF-8، كل اسم منتهٍ بصفر؛ الإزاحة 0 = بلا اسم)
  grid: header (float64 minLon, minLat, cell; uint32 cols, rows) ثم cellStart[(cols*rows)+1] ثم info indices
الاستخدام: build_graph.py in.osm.pbf regions.json outdir version
"""
import sys, json, struct, math
from array import array
import osmium

src, regions_path, outdir, version = sys.argv[1:5]
CLASSES = ["motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential", "living_street",
           "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link", "service"]
CLASS_ID = {c: i for i, c in enumerate(CLASSES)}
DEFAULT_SPEED = {"motorway": 110, "trunk": 90, "primary": 70, "secondary": 60, "tertiary": 50, "unclassified": 40,
                 "residential": 30, "living_street": 15, "motorway_link": 60, "trunk_link": 50, "primary_link": 45,
                 "secondary_link": 40, "tertiary_link": 35, "service": 20}
F_ONEWAY, F_REVERSE_ONEWAY, F_ROUNDABOUT, F_TOLL = 1, 2, 4, 8

def parse_speed(v):
    if not v:
        return None
    try:
        n = float(v.split(";")[0].split()[0])
        if "mph" in v:
            n *= 1.609
        return int(n) if 5 <= n <= 140 else None
    except ValueError:
        return None

class Ways(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.ways = []          # (node ids array, coords array, class, speed, flags, name)
        self.use = {}           # node id -> عدد مرات الاستخدام
    def way(self, w):
        t = w.tags
        hw = t.get("highway")
        if hw not in CLASS_ID:
            return
        if hw == "service" and t.get("service") in ("parking_aisle", "driveway", "drive-through", "emergency_access"):
            return
        if t.get("access") in ("private", "no") or t.get("motor_vehicle") in ("private", "no") or t.get("area") == "yes":
            return
        ids, coords = array("q"), array("i")
        try:
            for n in w.nodes:
                ids.append(n.ref)
                coords.append(int(round(n.location.lat * 1e6))); coords.append(int(round(n.location.lon * 1e6)))
        except osmium.InvalidLocationError:
            return
        if len(ids) < 2:
            return
        flags = 0
        ow = t.get("oneway", "")
        jn = t.get("junction", "")
        if ow in ("yes", "true", "1") or jn in ("roundabout", "circular") or hw in ("motorway",):
            flags |= F_ONEWAY
        if ow == "-1":
            flags |= F_ONEWAY | F_REVERSE_ONEWAY
        if ow == "no":
            flags &= ~F_ONEWAY
        if jn in ("roundabout", "circular"):
            flags |= F_ROUNDABOUT
        if t.get("toll") == "yes":
            flags |= F_TOLL
        speed = parse_speed(t.get("maxspeed")) or DEFAULT_SPEED[hw]
        name = t.get("name:ar") or t.get("name") or t.get("ref") or ""
        self.ways.append((ids, coords, CLASS_ID[hw], speed, flags, name))
        for k, n in enumerate(ids):
            self.use[n] = self.use.get(n, 0) + (2 if k in (0, len(ids) - 1) else 1)

h = Ways()
h.apply_file(src, locations=True, idx="flex_mem")
print("ways", len(h.ways), "nodes", len(h.use), flush=True)

def hav(a1, o1, a2, o2):
    la1, lo1, la2, lo2 = (math.radians(x / 1e6) for x in (a1, o1, a2, o2))
    d = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(d))

# تقسيم الطرق إلى حواف بين التقاطعات (رأس = نهاية طريق أو نقطة مشتركة بين طريقين)
edges = []   # (nodeA, nodeB, latlon of A, latlon of B, mid coords array, length, class, speed, flags, name)
for ids, coords, cls, speed, flags, name in h.ways:
    start = 0
    for k in range(1, len(ids)):
        if k == len(ids) - 1 or h.use.get(ids[k], 0) > 1:
            mid = coords[2 * (start + 1): 2 * k]
            length = 0.0
            for q in range(start, k):
                length += hav(coords[2*q], coords[2*q+1], coords[2*q+2], coords[2*q+3])
            if ids[start] != ids[k] or length > 1:
                edges.append((ids[start], ids[k], coords[2*start], coords[2*start+1], coords[2*k], coords[2*k+1],
                              mid, length, cls, speed, flags, name))
            start = k
print("edges", len(edges), flush=True)
del h

def write_region(rid, bbox):
    minlon, minlat, maxlon, maxlat = bbox
    def inside(lat, lon):
        return minlat * 1e6 <= lat <= maxlat * 1e6 and minlon * 1e6 <= lon <= maxlon * 1e6
    sel = [e for e in edges if inside(e[2], e[3]) or inside(e[4], e[5])]
    vid = {}
    vlat, vlon = array("i"), array("i")
    def vertex(n, lat, lon):
        v = vid.get(n)
        if v is None:
            v = vid[n] = len(vlat); vlat.append(lat); vlon.append(lon)
        return v
    names = bytearray(b"\0"); name_off = {"": 0}
    info = bytearray(); geom = array("i"); out = {}
    for i, (a, b, la, oa, lb, ob, mid, length, cls, speed, flags, name) in enumerate(sel):
        va, vb = vertex(a, la, oa), vertex(b, lb, ob)
        if name not in name_off:
            name_off[name] = len(names); names += name.encode("utf-8") + b"\0"
        info += struct.pack("<fBBBBIII", length, speed, cls, flags, 0, name_off[name], len(geom) // 2, len(mid) // 2)
        geom.extend(mid)
        fwd = not (flags & F_ONEWAY) or not (flags & F_REVERSE_ONEWAY)
        bwd = not (flags & F_ONEWAY) or bool(flags & F_REVERSE_ONEWAY)
        if fwd: out.setdefault(va, []).append((vb, i))
        if bwd: out.setdefault(vb, []).append((va, i | 0x80000000))
    n = len(vlat)
    first = array("I", [0] * (n + 1)); directed = array("I")
    for v in range(n):
        first[v] = len(directed) // 2
        for t, inf in out.get(v, ()):
            directed.append(t); directed.append(inf)
    first[n] = len(directed) // 2
    # شبكة مكانية للعثور على أقرب حافة
    cell = 0.01
    cols = int(math.ceil((maxlon - minlon) / cell)) + 1
    rows = int(math.ceil((maxlat - minlat) / cell)) + 1
    buckets = {}
    for i, e in enumerate(sel):
        pts = [(e[2], e[3])] + [(e[6][2*j], e[6][2*j+1]) for j in range(len(e[6]) // 2)] + [(e[4], e[5])]
        cells = set()
        for lat, lon in pts:
            c = int((lon / 1e6 - minlon) / cell); r = int((lat / 1e6 - minlat) / cell)
            if 0 <= c < cols and 0 <= r < rows:
                cells.add(r * cols + c)
        for k in cells:
            buckets.setdefault(k, []).append(i)
    cell_start = array("I", [0] * (cols * rows + 1)); cell_items = array("I")
    for k in range(cols * rows):
        cell_start[k] = len(cell_items)
        cell_items.extend(buckets.get(k, ()))
    cell_start[cols * rows] = len(cell_items)

    path = f"{outdir}/roads-{rid}.samtroute"
    with open(path, "wb") as f:
        f.write(b"SAMTRT1\0")
        f.write(struct.pack("<IIIIIIdddII", int(version), n, len(sel), len(directed) // 2, len(geom) // 2, len(names),
                            minlon, minlat, cell, cols, rows))
        for v in range(n):
            f.write(struct.pack("<ii", vlat[v], vlon[v]))
        first.tofile(f); directed.tofile(f); f.write(info); geom.tofile(f); f.write(names)
        cell_start.tofile(f); cell_items.tofile(f)
    import os
    size = os.path.getsize(path)
    print(rid, "vertices", n, "edges", len(sel), "geom", len(geom) // 2, "MB", round(size / 1e6, 1), flush=True)
    return {"id": rid, "file": f"roads-{rid}.samtroute", "bytes": size, "version": int(version)}

regions = json.load(open(regions_path))
manifest = [write_region(r["id"], r["bbox"]) for r in regions]
json.dump({"version": int(version), "regions": manifest}, open(f"{outdir}/roads-manifest.json", "w"))
