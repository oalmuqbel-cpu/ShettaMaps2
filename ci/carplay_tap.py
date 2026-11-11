# يحدد نافذة CarPlay في المحاكي وينقر على أيقونة التطبيق لفتح واجهة الملاحة
import re, subprocess, sys
raw = open(sys.argv[1]).read().strip()
print("windows:", raw)
parts = [p.strip() for p in raw.split(",")]
n = len(parts) // 5  # أسماء ثم مواقع (x,y) ثم أحجام (w,h)
names = parts[:n]
pos = [(int(float(parts[n + 2*i])), int(float(parts[n + 2*i + 1]))) for i in range(n)]
size = [(int(float(parts[3*n + 2*i])), int(float(parts[3*n + 2*i + 1]))) for i in range(n)]
idx = next((i for i, nm in enumerate(names) if "carplay" in nm.lower()), None)
if idx is None:
    sys.exit("CarPlay window not found")
(x, y), (w, h) = pos[idx], size[idx]
# محتوى CarPlay 800x480 مع شريط عنوان تقريبي 28 نقطة؛ نستخدم نسبة العرض
title = 28
scale = w / 800.0
content_h = 480 * scale
top = y + (h - content_h)  # المحتوى في أسفل النافذة بعد شريط العنوان
cx, cy = (float(sys.argv[2]), float(sys.argv[3])) if len(sys.argv) > 3 else (205, 280)
tx, ty = int(x + cx * scale), int(top + cy * scale)
print("window", names[idx], x, y, w, h, "tap", tx, ty)
subprocess.run(["osascript", "-e", 'tell application "Simulator" to activate'])
subprocess.run(["cliclick", f"c:{tx},{ty}"])
