"""Generate the CQUTmux app icons: a terminal prompt on each theme's colour.

Renders the primary icon into the asset catalogs, and the alternate icons into
App/Icons/ as loose 60pt files — `CFBundleAlternateIcons` names files on disk
rather than catalog entries, and the alternate set is declared in project.yml
because XcodeGen's asset support does not surface one.

Apple scales a single 1024px image down to every size it needs, except the
alternate-icon path, which looks for the exact `60x60@2x`/`@3x` names it was
told about. So the alternates are rendered at both.
"""
import pathlib

from PIL import Image, ImageDraw

S = 1024

# (name, gradient top, gradient bottom, ink) — the primary is the app's own
# green; the alternates keep the same mark on a different surface so a user
# changing the icon is choosing a colour, not a different app.
ICONS = [
    ("AppIcon", (34, 197, 94), (13, 122, 56), (9, 46, 30)),
    ("Nebula", (147, 112, 240), (76, 40, 158), (24, 14, 48)),
    ("Aurora", (56, 189, 248), (12, 74, 138), (6, 28, 54)),
]


def render(top, bottom, ink):
    """One icon at 1024px. The mark is the same in all of them."""
    img = Image.new("RGB", (S, S), top)
    d = ImageDraw.Draw(img)

    # Vertical gradient: brighter at the top-left, deeper at the bottom-right,
    # so the icon reads as a lit surface rather than flat paint.
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
    return img


OUT = pathlib.Path(__file__).resolve().parent.parent

for name, top, bottom, ink in ICONS:
    img = render(top, bottom, ink)

    if name == "AppIcon":
        # The primary lives in both catalogs, so the watch icon matches the
        # phone's without a second script run.
        for target in ("App", "Watch"):
            dest = OUT / target / "Assets.xcassets/AppIcon.appiconset/AppIcon.png"
            dest.parent.mkdir(parents=True, exist_ok=True)
            img.save(dest)
            print("wrote", dest.relative_to(OUT))
        continue

    # Alternates: the exact names CFBundleAlternateIcons points at.
    base = OUT / "App/Icons"
    base.mkdir(parents=True, exist_ok=True)
    for scale, side in ((2, 120), (3, 180)):
        dest = base / f"{name}60x60@{scale}x.png"
        img.resize((side, side), Image.LANCZOS).save(dest)
        print("wrote", dest.relative_to(OUT))

print("size", S)