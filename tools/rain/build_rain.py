"""
توقعات الأمطار لـ«سَمْت»: نموذج GFS من NOAA (ملكية عامة، يُستخدم تجاريًا مجانًا) بدقة 0.25°،
كل ساعة لمدة 48 ساعة فوق الجزيرة العربية. نحسب معدل المطر لكل ساعة، ننعّم الشبكة،
ثم نستخرج أشكالًا ناعمة (حدود متساوية الشدة) لأربعة مستويات، ونخرجها ملفًا مضغوطًا واحدًا للتطبيق.
"""
import json, sys, time, datetime as dt, urllib.request, urllib.error, os
import numpy as np
from scipy import ndimage
import eccodes
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from shapely.geometry import Polygon, MultiPolygon
from shapely.ops import unary_union

TOP, BOTTOM, LEFT, RIGHT = 34, 12, 34, 60
HOURS = 48
LEVELS = [0.2, 1.0, 4.0, 10.0]          # ملم/ساعة: خفيف، متوسط، غزير، غزير جدًا (نفس مقياس التطبيق)
UPSAMPLE = 4                             # 0.25° ← 0.0625° لحدود ناعمة
OUT = sys.argv[1] if len(sys.argv) > 1 else "rain-forecast.json"

def fetch(url, path, tries=4):
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Samt-rain/1.0 (github.com/oalmuqbel-cpu/ShettaMaps2)"})
            with urllib.request.urlopen(req, timeout=90) as r, open(path, "wb") as f:
                f.write(r.read())
            if os.path.getsize(path) > 100:
                return True
        except Exception as e:
            print("fetch error", e, url[-80:])
        time.sleep(10 * (i + 1))
    return False

def latest_run():
    """أحدث دورة GFS متاحة كاملة حتى الساعة 48."""
    now = dt.datetime.utcnow()
    for back in range(0, 30, 6):
        t = now - dt.timedelta(hours=back + 4)   # تصبح متاحة بعد قرابة 4 ساعات
        run = t.replace(hour=(t.hour // 6) * 6, minute=0, second=0, microsecond=0)
        url = file_url(run, HOURS)
        if fetch(url, "/tmp/probe.grb", tries=1):
            return run
    raise SystemExit("no GFS run available")

def file_url(run, fh):
    d, h = run.strftime("%Y%m%d"), run.strftime("%H")
    return ("https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_0p25_1hr.pl"
            f"?dir=%2Fgfs.{d}%2F{h}%2Fatmos&file=gfs.t{h}z.pgrb2.0p25.f{fh:03d}"
            f"&var_PRATE=on&lev_surface=on&subregion=&toplat={TOP}&leftlon={LEFT}&rightlon={RIGHT}&bottomlat={BOTTOM}")

def read(path):
    with open(path, "rb") as f:
        gid = eccodes.codes_grib_new_from_file(f)
        step = eccodes.codes_get(gid, "stepRange")
        ni, nj = eccodes.codes_get(gid, "Ni"), eccodes.codes_get(gid, "Nj")
        vals = eccodes.codes_get_values(gid).reshape(nj, ni)
        la1, la2 = eccodes.codes_get(gid, "latitudeOfFirstGridPointInDegrees"), eccodes.codes_get(gid, "latitudeOfLastGridPointInDegrees")
        lo1, lo2 = eccodes.codes_get(gid, "longitudeOfFirstGridPointInDegrees"), eccodes.codes_get(gid, "longitudeOfLastGridPointInDegrees")
        eccodes.codes_release(gid)
    s, e = (int(x) for x in step.split("-")) if "-" in step else (int(step), int(step))
    lats = np.linspace(la1, la2, nj)
    lons = np.linspace(lo1, lo2, ni)
    if lats[0] > lats[-1]:
        lats, vals = lats[::-1], vals[::-1, :]
    return s, e, lats, lons, vals * 3600.0   # كغ/م²/ث ← ملم/ساعة

def to_rings(geom):
    polys = [geom] if isinstance(geom, Polygon) else list(getattr(geom, "geoms", []))
    out = []
    for p in polys:
        if p.is_empty or p.area < 0.004:
            continue
        p = p.simplify(0.02, preserve_topology=True)
        rings = [p.exterior] + list(p.interiors)
        out.append([[[round(x, 3), round(y, 3)] for x, y in r.coords] for r in rings])
    return out

def bands(lats, lons, rate):
    """أشكال (معدل ≥ الحد) لكل مستوى، بحدود ناعمة."""
    fine = ndimage.zoom(rate, UPSAMPLE, order=3)
    fine = ndimage.gaussian_filter(fine, 1.0)
    flats = np.linspace(lats[0], lats[-1], fine.shape[0])
    flons = np.linspace(lons[0], lons[-1], fine.shape[1])
    levels = []
    for li, th in enumerate(LEVELS, start=1):
        if fine.max() < th:
            break
        cs = plt.contourf(flons, flats, fine, levels=[th, 1e9])
        polys = []
        for path in cs.get_paths():
            for poly in path.to_polygons():
                if len(poly) >= 4:
                    polys.append(Polygon(poly).buffer(0))
        plt.close("all")
        if not polys:
            continue
        # الحلقات المتداخلة: الخارجية شكل والداخلية ثقوب، يعالجها الاتحاد بالفرق المتماثل
        merged = polys[0]
        for p in polys[1:]:
            merged = merged.symmetric_difference(p)
        rings = to_rings(merged.buffer(0))
        if rings:
            levels.append({"l": li, "p": rings})
    return levels

def main():
    run = latest_run()
    print("GFS run", run)
    avgs = {}
    frames = []
    prev = None
    lats = lons = None
    for fh in range(1, HOURS + 1):
        path = f"/tmp/f{fh:03d}.grb"
        if not fetch(file_url(run, fh), path):
            print("missing", fh); break
        s, e, lats, lons, avg = read(path)
        avgs[(s, e)] = avg
        # معدل الساعة الأخيرة من متوسط نافذة متزايدة (تبدأ من جديد كل 6 ساعات)
        if e - s <= 1:
            rate = avg
        elif (s, e - 1) in avgs:
            rate = (avg * (e - s) - avgs[(s, e - 1)] * (e - 1 - s))
        else:
            rate = avg
        rate = np.clip(rate, 0, None)
        valid = run + dt.timedelta(hours=e)
        frames.append({"t": int(valid.replace(tzinfo=dt.timezone.utc).timestamp()), "levels": bands(lats, lons, rate),
                       "max": round(float(rate.max()), 2)})
        if fh % 6 == 0:
            print(fh, "step", f"{s}-{e}", "max mm/h", round(float(rate.max()), 2), "shapes",
                  sum(len(l["p"]) for l in frames[-1]["levels"]))
        time.sleep(0.6)   # أدب مع خادم NOAA
    out = {"source": "NOAA GFS 0.25°", "run": int(run.replace(tzinfo=dt.timezone.utc).timestamp()),
           "generated": int(time.time()), "bbox": [BOTTOM, LEFT, TOP, RIGHT], "levels": LEVELS, "frames": frames}
    if len(frames) < 24:
        raise SystemExit(f"too few frames: {len(frames)}")
    with open(OUT, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("frames", len(frames), "bytes", os.path.getsize(OUT))

    # صورة معاينة للتحقق البصري (ساعة فيها أكبر مطر)
    best = max(frames, key=lambda fr: fr["max"])
    fig, ax = plt.subplots(figsize=(7, 6))
    colors = {1: "#8cccfa", 2: "#338cf2", 3: "#1a40cc", 4: "#8c26bf"}
    for lv in best["levels"]:
        for poly in lv["p"]:
            ax.fill(*zip(*poly[0]), color=colors[lv["l"]], alpha=0.6, lw=0)
    ax.set_xlim(LEFT, RIGHT); ax.set_ylim(BOTTOM, TOP); ax.set_aspect("equal")
    ax.set_title(f"valid {dt.datetime.utcfromtimestamp(best['t'])} max {best['max']} mm/h")
    fig.savefig(OUT.replace(".json", "-preview.png"), dpi=80)

if __name__ == "__main__":
    main()
