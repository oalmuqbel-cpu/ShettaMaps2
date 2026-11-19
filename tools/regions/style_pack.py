#!/usr/bin/env python3
"""حزمة النمط للخرائط المنزلة: نمط liberty من OpenFreeMap مع الخطوط والرموز محليًا، في ملف zip غير مضغوط (store)."""
import json, os, sys, urllib.request, zipfile, time, urllib.parse

STYLE = "https://tiles.openfreemap.org/styles/liberty"
UA = {"User-Agent": "Samt-style-pack/1.0 (github.com/oalmuqbel-cpu/ShettaMaps2)"}

def get(url, tries=4):
    for i in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
                return r.read()
        except Exception as e:
            print("retry", url[-60:], e); time.sleep(3 * (i + 1))
    raise SystemExit("failed " + url)

def main(out):
    style = json.loads(get(STYLE))
    fonts = set()
    for l in style["layers"]:
        tf = (l.get("layout") or {}).get("text-font")
        if isinstance(tf, list) and all(isinstance(x, str) for x in tf):
            fonts.add(",".join(tf))
        elif tf:
            # تعبيرات: نجمع أي نص يشبه اسم خط
            for x in json.dumps(tf).split('"'):
                if x.startswith("Noto"): fonts.add(x)
    single = sorted({f for fs in fonts for f in fs.split(",")})
    print("fonts", single)
    glyphs = style["glyphs"]; sprite = style["sprite"] if isinstance(style["sprite"], str) else style["sprite"][0]["url"]
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_STORED) as z:
        z.writestr("style.json", json.dumps(style, ensure_ascii=False))
        for sfx in ("", "@2x"):
            for ext in (".json", ".png"):
                z.writestr(f"sprites/sprite{sfx}{ext}", get(sprite + sfx + ext))
        # MapLibre يطلب كل خط في المجموعة على حدة عند الحاجة؛ ننزّل النطاقات المستخدمة للعربية واللاتينية
        ranges = list(range(0, 1024, 256)) + list(range(1536, 2048, 256)) + [8192, 64256, 65024, 65280]
        for f in single:
            for start in ranges:
                rng = f"{start}-{start + 255}"
                url = glyphs.replace("{fontstack}", urllib.parse.quote(f)).replace("{range}", rng)
                try:
                    z.writestr(f"fonts/{f}/{rng}.pbf", get(url, tries=2))
                except SystemExit:
                    print("missing glyph", f, rng)
    print("style pack", os.path.getsize(out))

if __name__ == "__main__":
    main(sys.argv[1])
