# يبني خلايا SQLite للردميات: جدول roads + فهرس R*Tree، والهندسة مرمّزة Polyline (1e-5) بعد التبسيط.
# المصادر: OpenStreetMap (ODbL) و Microsoft Road Detections (ODbL) لما لا يوجد في OSM.
import json, math, os, sys, sqlite3, zlib, hashlib, time
import numpy as np, duckdb

SRC, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)
DIRT_SURF = {"unpaved", "dirt", "sand", "gravel", "ground", "earth", "compacted", "fine_gravel", "mud", "soil", "rock", "pebblestone", "grass"}
ROAD_HW = {"track", "unclassified", "service", "residential", "living_street", "tertiary", "secondary", "primary", "trunk", "road"}
BOX = (12.0, 33.0, 34.0, 60.0)  # minLat maxLat minLon maxLon
CELL = 2.0
GRID = 30.0  # متر لخلايا المطابقة
K = 111_320.0


def hav(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[1], a[0], b[1], b[0]))
    x = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(x))


def simplify(pts, tol):
    if len(pts) < 3:
        return pts
    kx = math.cos(math.radians(pts[0][1])) * K
    xy = [(p[0] * kx, p[1] * 110_540) for p in pts]
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
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
            keep[idx] = True
            stack += [(a, idx), (idx, b)]
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


def cell_ids(pts):
    """خلايا الشبكة (30 م) التي يمر بها الخط بعد تكثيفه كل 15 م (محسوبة بـ numpy)."""
    a = np.asarray(pts, dtype=np.float64)[:, :2]
    lat0 = math.radians(a[0, 1])
    x = a[:, 0] * K * math.cos(lat0); y = a[:, 1] * 110_540
    dx, dy = np.diff(x), np.diff(y)
    n = np.maximum(1, (np.hypot(dx, dy) // 15).astype(np.int64))
    seg = np.repeat(np.arange(len(n)), n)
    t = (np.arange(n.sum()) - np.repeat(np.cumsum(n) - n, n)) / np.repeat(n, n)
    xs = np.concatenate([x[seg] + dx[seg] * t, x[-1:]]); ys = np.concatenate([y[seg] + dy[seg] * t, y[-1:]])
    return ((ys // GRID).astype(np.int64) << 24) + (xs // GRID).astype(np.int64)


roads = []      # (kind, name, pts)
covered = []    # خلايا كل الطرق في OSM لاستبعاد ما يكررها من Microsoft
covered_n = 0
t0 = time.time()
for line in open(SRC):
    f = json.loads(line.lstrip("\x1e")); p = f["properties"]; g = f["geometry"]["coordinates"]
    hw = p.get("highway")
    if not hw or len(g) < 2:
        continue
    covered.append(cell_ids(g)); covered_n += len(covered[-1])
    if len(covered) > 200_000:
        covered = [np.unique(np.concatenate(covered))]
    surf = p.get("surface")
    if not (hw == "track" or (hw in ROAD_HW and surf in DIRT_SURF)):
        continue
    name = p.get("name:ar") or p.get("name") or ""
    roads.append(("osm_track" if hw == "track" else "osm_unpaved", name[:60], simplify(g, 4)))
cov = np.unique(np.concatenate(covered))
print("osm dirt ways", len(roads), "covered samples", covered_n, "cells", len(cov), round(time.time() - t0), "s", flush=True)
del covered

con = duckdb.connect()
con.execute("INSTALL httpfs; LOAD httpfs; INSTALL spatial; LOAD spatial;")
con.execute("SET s3_region='us-west-2'; SET s3_url_style='path'; SET s3_endpoint='s3.us-west-2.amazonaws.com';")
base = "s3://us-west-2.opendata.source.coop/nlebovits/microsoft-ml-road-detections/road-detections/by_country"
files = [r[0] for r in con.execute(f"SELECT file FROM glob('{base}/*/*.parquet')").fetchall()]
files = [f for f in files if any(f"country={c}/" in f for c in ("SAU", "ARE", "KWT", "QAT", "BHR", "OMN"))]
print("ms files", len(files), files[:3], flush=True)
assert files, "no Microsoft files matched"
local = "ms.parquet"
if not os.path.exists(local):
    flist = ",".join(f"'{f}'" for f in files)
    con.execute(f"COPY (SELECT ST_AsText(geometry::GEOMETRY) AS wkt FROM read_parquet([{flist}])) TO '{local}' (FORMAT parquet)")
print("ms downloaded", round(os.path.getsize(local) / 1e6), "MB", round(time.time() - t0), "s", flush=True)
reader = con.execute(f"SELECT wkt FROM read_parquet('{local}')").fetch_record_batch(100_000)
ms_total = ms_kept = 0
shifts = np.array([(dy << 24) + dx for dy in (-1, 0, 1) for dx in (-1, 0, 1)], dtype=np.int64)
for batch in reader:
    for wkt in batch.column(0).to_pylist():
        ms_total += 1
        if not wkt:
            continue
        try:
            pts = [tuple(map(float, xy.split()[:2])) for xy in wkt[wkt.index("(") + 1:-1].replace("(", "").replace(")", "").split(",")]
        except Exception:
            continue
        if len(pts) < 2:
            continue
        a = np.asarray(pts)
        km = np.hypot(np.diff(a[:, 0]) * K * math.cos(math.radians(a[0, 1])), np.diff(a[:, 1]) * 110_540).sum()
        if km < 80:
            continue
        ids = cell_ids(pts)
        near = np.isin((ids[:, None] + shifts[None, :]).ravel(), cov).reshape(len(ids), -1).any(axis=1)
        if near.mean() > 0.5:
            continue  # موجود في OSM
        roads.append(("ms_detected", "", simplify(pts, 6)))
        ms_kept += 1
    print("ms", ms_total, "kept", ms_kept, round(time.time() - t0), "s", flush=True)
print("ms total", ms_total, "kept", ms_kept)

cells = {}
for kind, name, pts in roads:
    lats = [p[1] for p in pts]; lons = [p[0] for p in pts]
    mid = pts[len(pts) // 2]
    if not (BOX[0] <= mid[1] <= BOX[1] and BOX[2] <= mid[0] <= BOX[3]):
        continue
    key = (int(math.floor(mid[1] / CELL) * CELL), int(math.floor(mid[0] / CELL) * CELL))
    cells.setdefault(key, []).append((kind, name, min(lats), max(lats), min(lons), max(lons), encode(pts)))

manifest = {"version": 1, "built": time.strftime("%Y-%m-%d"), "cellSize": CELL,
            "attribution": "© OpenStreetMap contributors (ODbL); Microsoft Road Detections (ODbL)", "cells": []}
for (la, lo), rows in sorted(cells.items()):
    name = f"dirt_{la}_{lo}.sqlite"
    path = os.path.join(OUT, name)
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE roads(id INTEGER PRIMARY KEY, kind TEXT, name TEXT, poly TEXT)")
    db.execute("CREATE VIRTUAL TABLE roads_idx USING rtree(id, minLat, maxLat, minLon, maxLon)")
    for i, r in enumerate(rows, 1):
        db.execute("INSERT INTO roads VALUES(?,?,?,?)", (i, r[0], r[1], r[6]))
        db.execute("INSERT INTO roads_idx VALUES(?,?,?,?,?)", (i, r[2], r[3], r[4], r[5]))
    db.commit(); db.execute("VACUUM"); db.close()
    raw = open(path, "rb").read()
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    z = comp.compress(raw) + comp.flush()
    open(path + ".z", "wb").write(z)
    os.remove(path)
    manifest["cells"].append({"file": name + ".z", "lat": la, "lon": lo, "roads": len(rows), "bytes": len(z),
                              "rawBytes": len(raw), "sha256": hashlib.sha256(z).hexdigest(),
                              "osm": sum(1 for r in rows if r[0] != "ms_detected"),
                              "detected": sum(1 for r in rows if r[0] == "ms_detected")})
json.dump(manifest, open(os.path.join(OUT, "manifest.json"), "w"), ensure_ascii=False, indent=1)
tot = sum(c["bytes"] for c in manifest["cells"])
print("cells", len(manifest["cells"]), "total MB", round(tot / 1e6, 1))
for c in sorted(manifest["cells"], key=lambda c: -c["bytes"])[:12]:
    print(c["file"], c["roads"], "osm", c["osm"], "detected", c["detected"], round(c["bytes"] / 1e6, 2), "MB")
