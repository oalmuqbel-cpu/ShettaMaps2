# يختار أول محاكي آيفون متاح لتشغيل الاختبارات
import json, subprocess, sys
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
best = None
for runtime, devices in data["devices"].items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        if d.get("isAvailable") and d["name"].startswith("iPhone"):
            ver = runtime.split("iOS-")[-1]
            key = tuple(int(x) for x in ver.split("-") if x.isdigit())
            if best is None or key > best[0]:
                best = (key, d["udid"])
if not best:
    sys.exit("No iPhone simulator available")
print(best[1])
