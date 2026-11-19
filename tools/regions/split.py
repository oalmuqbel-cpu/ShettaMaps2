#!/usr/bin/env python3
"""يقسم ملف MBTiles للجزيرة العربية إلى ملفات بالمناطق (نفس المربعات، دون إعادة بناء)."""
import json, math, sqlite3, sys, os, hashlib

def tile_range(bbox, z):
    w, s, e, n = bbox
    def x(lon): return int((lon + 180) / 360 * (1 << z))
    def y(lat):
        r = math.radians(lat)
        return int((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * (1 << z))
    x0, x1 = x(w), x(e)
    y0, y1 = y(n), y(s)              # XYZ: الشمال أصغر
    return x0, x1, y0, y1

def split(src, regions, outdir):
    os.makedirs(outdir, exist_ok=True)
    s = sqlite3.connect(src)
    meta = dict(s.execute("select name, value from metadata").fetchall())
    minz, maxz = int(meta.get("minzoom", 0)), int(meta.get("maxzoom", 14))
    manifest = []
    for r in regions:
        path = os.path.join(outdir, f"samt-{r['id']}.mbtiles")
        if os.path.exists(path): os.remove(path)
        d = sqlite3.connect(path)
        d.execute("create table metadata (name text, value text)")
        d.execute("create table tiles (zoom_level integer, tile_column integer, tile_row integer, tile_data blob)")
        d.execute("create unique index tile_index on tiles (zoom_level, tile_column, tile_row)")
        m = dict(meta); m["name"] = r["title"]; m["bounds"] = ",".join(str(v) for v in r["bbox"])
        d.executemany("insert into metadata values (?, ?)", list(m.items()))
        count = 0
        for z in range(minz, maxz + 1):
            x0, x1, y0, y1 = tile_range(r["bbox"], z)
            # MBTiles يخزن الصفوف بنظام TMS (معكوس)
            t0, t1 = (1 << z) - 1 - y1, (1 << z) - 1 - y0
            rows = s.execute("select zoom_level, tile_column, tile_row, tile_data from tiles where zoom_level=? "
                             "and tile_column between ? and ? and tile_row between ? and ?", (z, x0, x1, t0, t1))
            batch = rows.fetchall()
            d.executemany("insert into tiles values (?, ?, ?, ?)", batch)
            count += len(batch)
        d.commit(); d.execute("vacuum"); d.close()
        size = os.path.getsize(path)
        h = hashlib.sha256(open(path, "rb").read()).hexdigest()
        print(r["id"], count, "tiles", size // (1 << 20), "MB")
        manifest.append({**r, "file": os.path.basename(path), "bytes": size, "sha256": h, "tiles": count,
                         "minzoom": minz, "maxzoom": maxz})
    return manifest

if __name__ == "__main__":
    src, regions_json, outdir, version = sys.argv[1:5]
    regions = json.load(open(regions_json, encoding="utf-8"))
    mani = split(src, regions, outdir)
    json.dump({"version": int(version), "schema": "openmaptiles", "attribution": "© OpenMapTiles © OpenStreetMap contributors",
               "styleZip": "samt-style.zip", "regions": mani},
              open(os.path.join(outdir, "manifest.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
