# يختار محاكيًا متاحًا (آيفون افتراضيًا، أو آيباد بالوسيط ipad) بأحدث نظام
import json, subprocess, sys
kind = "iPad" if len(sys.argv) > 1 and sys.argv[1].lower() == "ipad" else "iPhone"
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
best = None
for runtime, devices in data["devices"].items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        if d.get("isAvailable") and d["name"].startswith(kind):
            # للآيباد نفضّل Pro بحجم 13 بوصة، وللآيفون Pro
            pref = 1 if ("Pro" in d["name"]) else 0
            ver = runtime.split("iOS-")[-1]
            key = tuple(int(x) for x in ver.split("-") if x.isdigit()) + (pref,)
            if best is None or key > best[0]:
                best = (key, d["udid"])
if not best:
    sys.exit(f"No {kind} simulator available")
print(best[1])
