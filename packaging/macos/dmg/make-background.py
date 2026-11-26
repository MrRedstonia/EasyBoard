# Draws the .dmg window background (background.png and background@2x.png): the README banner top
# left and an arrow from the app icon to Applications, in the app icon's colors.
# Usage (needs Pillow): python3 packaging/macos/dmg/make-background.py . packaging/macos/dmg
import sys
from PIL import Image, ImageDraw

repo, out = sys.argv[1], sys.argv[2]
W, H = 540, 400            # taller than the window, so nothing dark shows below it
ICON_Y = 165               # icon centers (must match dmg-settings.py)
APP_X, APPS_X = 145, 395

def draw(scale):
    S = 4 * scale          # draw 4x larger, then shrink: smooth edges
    img = Image.new("RGBA", (W * S, H * S), (255, 255, 255, 255))
    d = ImageDraw.Draw(img)
    # arrow: shaft + head, a gradient from the icon's cyan to its pink
    x0, x1, y = 248 * S, 292 * S, ICON_Y * S
    t = 3.2 * S
    grad = Image.new("RGBA", img.size)
    gd = ImageDraw.Draw(grad)
    c0, c1 = (111, 208, 227), (217, 127, 232)
    for x in range(x0 - 2 * S, x1 + 2 * S):
        f = (x - x0) / (x1 - x0)
        f = min(max(f, 0), 1)
        gd.line([(x, 0), (x, H * S)], fill=tuple(int(a + (b - a) * f) for a, b in zip(c0, c1)) + (255,))
    mask = Image.new("L", img.size, 0)
    md = ImageDraw.Draw(mask)
    md.line([(x0, y), (x1 - 2 * S, y)], fill=255, width=int(t))
    head = 13 * S
    md.line([(x1 - head, y - head), (x1, y)], fill=255, width=int(t))
    md.line([(x1 - head, y + head), (x1, y)], fill=255, width=int(t))
    for (cx, cy) in [(x0, y), (x1, y), (x1 - head, y - head), (x1 - head, y + head)]:
        r = t / 2
        md.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    img.paste(grad, (0, 0), mask)
    img = img.resize((W * scale, H * scale), Image.LANCZOS)
    # logo top left (the README banner: icon + "EasyBoard")
    logo = Image.open(f"{repo}/.github/readme/banner.png").convert("RGBA")
    lh = 24 * scale
    logo = logo.resize((round(logo.width * lh / logo.height), lh), Image.LANCZOS)
    img.alpha_composite(logo, (22 * scale, 20 * scale))
    return img.convert("RGB")

draw(1).save(f"{out}/background.png")
draw(2).save(f"{out}/background@2x.png")
print("ok")
