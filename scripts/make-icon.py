"""Generate the CQUTmux app icon: a terminal prompt on the app's green."""
import pathlib

from PIL import Image, ImageDraw

S = 1024
img = Image.new("RGB", (S, S), (22, 163, 74))
d = ImageDraw.Draw(img)

# Vertical gradient: brighter at the top-left, deeper at the bottom-right,
# so the icon reads as a lit surface rather than flat paint.
top, bottom = (34, 197, 94), (13, 122, 56)
for y in range(S):
    t = y / (S - 1)
    d.line(
        [(0, y), (S, y)],
        fill=tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)),
    )

# A soft highlight sweeping the upper-left corner.
glow = Image.new("L", (S, S), 0)
gd = ImageDraw.Draw(glow)
gd.ellipse([-S * 0.35, -S * 0.45, S * 0.75, S * 0.45], fill=70)
img = Image.composite(Image.new("RGB", (S, S), (255, 255, 255)), img, glow)
d = ImageDraw.Draw(img)

ink = (9, 46, 30)
w = 74  # stroke width, tuned to stay legible at 40pt

# Chevron ">" — two strokes meeting at a point.
cx, cy, arm = 0.40 * S, 0.44 * S, 0.17 * S
d.line([(cx - arm * 0.62, cy - arm), (cx + arm * 0.62, cy)], fill=ink, width=w)
d.line([(cx - arm * 0.62, cy + arm), (cx + arm * 0.62, cy)], fill=ink, width=w)
# Round the chevron's ends and corner by stamping discs, since PIL has no caps.
for pt in [(cx - arm * 0.62, cy - arm), (cx - arm * 0.62, cy + arm), (cx + arm * 0.62, cy)]:
    d.ellipse([pt[0] - w / 2, pt[1] - w / 2, pt[0] + w / 2, pt[1] + w / 2], fill=ink)

# Cursor block: the underscore an idle shell shows.
bx0, bx1 = 0.60 * S, 0.78 * S
by0, by1 = 0.66 * S, 0.66 * S + w
d.rounded_rectangle([bx0, by0, bx1, by1], radius=w / 2, fill=ink)

assert img.mode == "RGB"
OUT = pathlib.Path(__file__).resolve().parent.parent
for target in ("App", "Watch"):
    dest = OUT / target / "Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    dest.parent.mkdir(parents=True, exist_ok=True)
    img.save(dest)
    print("wrote", dest.relative_to(OUT))
print("size", img.size)
