#!/usr/bin/env python3
"""Generates scripts/dmg-background.png - a dark particle-network background
matching dangkhoabach.vn's site style, used behind the DMG installer window by
scripts/release.sh's create-dmg call. Deliberately lives under scripts/, not
SignalBarApp/Resources - it's only consumed on this Mac at DMG-build time and
must never get bundled into the shipping .app. Re-run this only if you want to
regenerate the look (new seed, different accent, etc.) - the PNG itself is
what's actually committed and used, not this script, at build time.
"""
import math
import random

from PIL import Image, ImageDraw

WIDTH, HEIGHT = 660, 400
ACCENT = (99, 102, 241)  # indigo, matches the app's pulse-glyph icon
random.seed(7)


def lerp(a, b, t):
    return a + (b - a) * t


def bg_color(x, y):
    t = (x / WIDTH + y / HEIGHT) / 2
    top = (7, 7, 16)
    bottom = (11, 11, 24)
    return tuple(int(lerp(top[i], bottom[i], t)) for i in range(3))


img = Image.new("RGB", (WIDTH, HEIGHT))
px = img.load()
for y in range(HEIGHT):
    for x in range(WIDTH):
        px[x, y] = bg_color(x, y)

draw = ImageDraw.Draw(img, "RGBA")

# Keep the horizontal band where the app icon / arrow / Applications alias sit
# (create-dmg places them at y=185, icon-size 100 -> roughly y in [135,235])
# a little sparser so the network doesn't visually compete with the icons.
ICON_BAND = (130, 240)

points = []
for _ in range(70):
    x = random.uniform(0, WIDTH)
    y = random.uniform(0, HEIGHT)
    if ICON_BAND[0] < y < ICON_BAND[1] and random.random() < 0.6:
        continue
    points.append((x, y))

MAX_DIST = 95
for i, (x1, y1) in enumerate(points):
    for x2, y2 in points[i + 1:]:
        d = math.hypot(x1 - x2, y1 - y2)
        if d < MAX_DIST:
            alpha = int(50 * (1 - d / MAX_DIST))
            draw.line([(x1, y1), (x2, y2)], fill=(150, 160, 200, alpha), width=1)

for x, y in points:
    accented = random.random() < 0.12
    if accented:
        for r, a in [(6, 18), (4, 30), (2, 60)]:
            draw.ellipse([x - r, y - r, x + r, y + r], fill=(*ACCENT, a))
        draw.ellipse([x - 1.5, y - 1.5, x + 1.5, y + 1.5], fill=(*ACCENT, 220))
    else:
        alpha = random.randint(60, 130)
        r = random.uniform(1.0, 1.8)
        draw.ellipse([x - r, y - r, x + r, y + r], fill=(190, 195, 220, alpha))

img.save("scripts/dmg-background.png")
print("Wrote scripts/dmg-background.png")
