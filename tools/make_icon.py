# يولّد أيقونة التطبيق 1024x1024 (تصميم أصلي: كثبان رملية وإبرة بوصلة)
import sys, math
from PIL import Image, ImageDraw, ImageFilter
S = 1024
img = Image.new("RGB", (S, S))
d = ImageDraw.Draw(img)
# سماء: تدرج من البرتقالي الفاتح إلى البيج
top, bottom = (232, 140, 56), (246, 226, 196)
for y in range(S):
    t = y / S
    c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    d.line([(0, y), (S, y)], fill=c)
# شمس
d.ellipse([610, 170, 830, 390], fill=(255, 240, 214))
def dune(y0, amp, phase, color):
    pts = [(0, S)]
    for x in range(0, S + 1, 8):
        y = y0 + amp * math.sin((x / S) * math.pi * 1.6 + phase)
        pts.append((x, y))
    pts.append((S, S))
    d.polygon(pts, fill=color)
dune(600, 60, 0.3, (214, 150, 86))
dune(700, 70, 2.1, (176, 104, 52))
dune(820, 50, 4.0, (107, 68, 35))
# إبرة البوصلة
cx, cy, L, W = 512, 470, 300, 70
north = [(cx, cy - L), (cx + W, cy), (cx - W, cy)]
south = [(cx, cy + L * 0.75), (cx + W, cy), (cx - W, cy)]
shadow = Image.new("L", (S, S), 0)
sd = ImageDraw.Draw(shadow)
sd.polygon([(x + 14, y + 18) for x, y in north + south[:1]], fill=110)
img.paste((60, 35, 15), (0, 0), shadow.filter(ImageFilter.GaussianBlur(18)))
d.polygon(north, fill=(255, 255, 255))
d.polygon([(cx, cy - L), (cx, cy), (cx - W, cy)], fill=(236, 236, 236))
d.polygon(south, fill=(107, 68, 35))
d.polygon([(cx, cy + L * 0.75), (cx, cy), (cx + W, cy)], fill=(86, 52, 24))
d.ellipse([cx - 26, cy - 26, cx + 26, cy + 26], fill=(232, 140, 56), outline=(255, 255, 255), width=8)
img.save(sys.argv[1], "PNG")
