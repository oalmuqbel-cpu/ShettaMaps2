# خلايا SQLite لحدود السرعة: جدول roads (الحد للأمام والخلف، الاسم، الخط) + فهرس R*Tree.
# المصدر: OpenStreetMap (ODbL). لا نخمن حدًا لطريق لا يحمل وسم maxspeed.
import json, math, os, re, sys, sqlite3, zlib, hashlib, time

SRC, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)
CELL = 1.0
BOX = (12.0, 33.0, 34.0, 60.0)
K = 111_320.0


def speed(v):
    """يحوّل قيمة maxspeed إلى كم/س أو None."""
    if not v:
        return None
    v = v.strip().lower()
    m = re.match(r"^(\d{2,3})\s*(mph)?", v)
    if not m:
        return None
    s = int(m.group(1))
    if m.group(2):
        s = round(s * 1.609)
    return s if 5 <= s <= 160 else None


def simplify(pts, tol):
    if len(pts) < 3:
        return pts
    kx = math.cos(math.radians(pts[0][1])) * K
    xy = [(p[0] * kx, p[1] * 110_540) for p in pts]
    keep = [False] * len(pts); keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        a, b = stack.pop()
        if b <= a + 1:
            continue
        ax, ay = xy[a]; bx, by = xy[b]; dx, dy = bx - ax, by - ay; l2 = dx * dx + dy * dy
        best, idx = 0.0, a
        for k in range(a + 1, b):
            px, py = xy[k]
            t = 0 if l2 == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / l2))
            d = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
            if d > best:
                best, idx = d, k
        if best > tol:
            keep[idx] = True; stack += [(a, idx), (idx, b)]
    return [p for p, k in zip(pts, keep) if k]


def enc_val(v):
    v = ~(v << 1) if v < 0 else (v << 1)
    out = []
    while v >= 0x20:
        out.append(chr((0x20 | (v & 0x1f)) + 63)); v >>= 5
    out.append(chr(v + 63))
    return "".join(out)


def encode(pts):
    s, plat, plon = [], 0, 0
    for lon, lat in pts:
        a, b = int(round(lat * 1e5)), int(round(lon * 1e5))
        s.append(enc_val(a - plat) + enc_val(b - plon)); plat, plon = a, b
    return "".join(s)


cells = {}
n = 0
for line in open(SRC):
    f = json.loads(line.lstrip("\x1e")); p = f["properties"]; g = f["geometry"]["coordinates"]
    if not p.get("highway") or len(g) < 2:
        continue
    both = speed(p.get("maxspeed"))
    fwd = speed(p.get("maxspeed:forward")) or both
    bwd = speed(p.get("maxspeed:backward")) or both
    if fwd is None and bwd is None:
        continue
    oneway = 1 if p.get("oneway") in ("yes", "1", "true") or p.get("junction") == "roundabout" or p.get("highway") == "motorway" else 0
    if p.get("oneway") == "-1":
        g = g[::-1]; oneway = 1
    pts = simplify([(c[0], c[1]) for c in g], 5)
    mid = pts[len(pts) // 2]
    if not (BOX[0] <= mid[1] <= BOX[1] and BOX[2] <= mid[0] <= BOX[3]):
        continue
    key = (int(math.floor(mid[1] / CELL)), int(math.floor(mid[0] / CELL)))
    lats = [q[1] for q in pts]; lons = [q[0] for q in pts]
    name = (p.get("name:ar") or p.get("name") or "")[:60]
    cells.setdefault(key, []).append((fwd or 0, bwd or 0, oneway, p.get("highway"), name,
                                      min(lats), max(lats), min(lons), max(lons), encode(pts)))
    n += 1
print("ways with maxspeed", n, "cells", len(cells), flush=True)

manifest = {"version": 1, "built": time.strftime("%Y-%m-%d"), "cellSize": CELL,
            "attribution": "© OpenStreetMap contributors (ODbL)", "cells": []}
for (la, lo), rows in sorted(cells.items()):
    name = f"speed_{la}_{lo}.sqlite"
    path = os.path.join(OUT, name)
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE roads(id INTEGER PRIMARY KEY, fwd INTEGER, bwd INTEGER, oneway INTEGER, hw TEXT, name TEXT, poly TEXT)")
    db.execute("CREATE VIRTUAL TABLE roads_idx USING rtree(id, minLat, maxLat, minLon, maxLon)")
    for i, r in enumerate(rows, 1):
        db.execute("INSERT INTO roads VALUES(?,?,?,?,?,?,?)", (i, r[0], r[1], r[2], r[3], r[4], r[9]))
        db.execute("INSERT INTO roads_idx VALUES(?,?,?,?,?)", (i, r[5], r[6], r[7], r[8]))
    db.commit(); db.execute("VACUUM"); db.close()
    raw = open(path, "rb").read()
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    z = comp.compress(raw) + comp.flush()
    open(path + ".z", "wb").write(z)
    os.remove(path)
    manifest["cells"].append({"file": name + ".z", "lat": la, "lon": lo, "roads": len(rows), "bytes": len(z),
                              "rawBytes": len(raw), "sha256": hashlib.sha256(z).hexdigest()})
json.dump(manifest, open(os.path.join(OUT, "manifest.json"), "w"), ensure_ascii=False, indent=1)
print("cells", len(manifest["cells"]), "total MB", round(sum(c["bytes"] for c in manifest["cells"]) / 1e6, 2))
for c in sorted(manifest["cells"], key=lambda c: -c["roads"])[:10]:
    print(c["file"], c["roads"], round(c["bytes"] / 1e3), "KB")
