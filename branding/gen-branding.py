#!/usr/bin/env python3
"""Generate the ScrapLinux artwork set from the master logo.

Everything visual in the distro comes out of this script so the palette stays
consistent: icon theme, SDDM/Plasma assets, wallpapers, and the Limine splash.

    ./gen-branding.py [path-to-master-logo.png]
"""
import os
import sys
import base64

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
MASTER = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "scraplinux-logo-master.png")

# Sampled from the master logo gradient.
VIOLET = (126, 50, 202)
INDIGO = (95, 91, 198)
TEAL = (3, 219, 187)
SNOW = (250, 252, 255)
ICE_DARK = (14, 18, 32)

ICON_SIZES = [16, 22, 24, 32, 36, 48, 64, 72, 96, 128, 192, 256, 512]


def ensure(*parts):
    d = os.path.join(HERE, *parts)
    os.makedirs(d, exist_ok=True)
    return d


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def diagonal_gradient(size, start=VIOLET, end=TEAL, mid=INDIGO):
    """Violet bottom-left to teal top-right, matching the master logo."""
    w, h = size
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            # Normalised distance along the bottom-left -> top-right diagonal.
            t = (x / max(w - 1, 1) + (h - 1 - y) / max(h - 1, 1)) / 2
            if t < 0.5:
                px[x, y] = lerp(start, mid, t * 2)
            else:
                px[x, y] = lerp(mid, end, (t - 0.5) * 2)
    return img


# The single source of truth for the letterform, in unit coordinates. The SVG
# paths below are the same numbers scaled by 512, so raster and vector match.
# Each leg is a pentagon: the fifth point is the counter apex, which sits below
# the letter apex so the top of the A stays solid instead of splitting.
A_OUTLINE = [
    [(0.5000, 0.0605), (0.4141, 0.0605), (0.0488, 0.9395),
     (0.2070, 0.9395), (0.5000, 0.2305)],
    [(0.5000, 0.0605), (0.5859, 0.0605), (0.9512, 0.9395),
     (0.7930, 0.9395), (0.5000, 0.2305)],
    [(0.2344, 0.6758), (0.7656, 0.6758), (0.8008, 0.7754), (0.1992, 0.7754)],
]


def draw_a(draw, box, colour=SNOW):
    """The ScrapLinux 'A': a broad triangle with a crossbar and flared feet."""
    x0, y0, x1, y1 = box
    w = x1 - x0
    h = y1 - y0
    for poly in A_OUTLINE:
        draw.polygon([(x0 + px * w, y0 + py * h) for px, py in poly], fill=colour)


SS = 4  # supersampling factor: PIL polygons are aliased, so draw big and shrink


def logo(size, transparent=False):
    """Render the logo at an arbitrary size, antialiased."""
    n = size * SS
    if transparent:
        img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    else:
        img = diagonal_gradient((size, size)).resize((n, n), Image.BICUBIC).convert("RGBA")
    draw_a(ImageDraw.Draw(img), (0, 0, n, n))
    return img.resize((size, size), Image.LANCZOS)


def mono(size, colour=SNOW):
    n = size * SS
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    draw_a(ImageDraw.Draw(img), (0, 0, n, n), colour=colour)
    return img.resize((size, size), Image.LANCZOS)


SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
  <defs>
    <linearGradient id="scraplinux" x1="0" y1="1" x2="1" y2="0">
      <stop offset="0%" stop-color="#7e32ca"/>
      <stop offset="50%" stop-color="#5f5bc6"/>
      <stop offset="100%" stop-color="#03dbbb"/>
    </linearGradient>
  </defs>
  <rect width="512" height="512" fill="url(#scraplinux)"/>
  <g fill="#fafcff">
    <path d="M256 31 L212 31 L25 481 L106 481 L256 118 Z"/>
    <path d="M256 31 L300 31 L487 481 L406 481 L256 118 Z"/>
    <path d="M120 346 L392 346 L410 397 L102 397 Z"/>
  </g>
</svg>
"""

SVG_MONO = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
  <g fill="currentColor">
    <path d="M256 31 L212 31 L25 481 L106 481 L256 118 Z"/>
    <path d="M256 31 L300 31 L487 481 L406 481 L256 118 Z"/>
    <path d="M120 346 L392 346 L410 397 L102 397 Z"/>
  </g>
</svg>
"""


def main():
    have_master = os.path.exists(MASTER)
    if have_master:
        master = Image.open(MASTER).convert("RGBA")
        print(f"master logo: {MASTER} {master.size}")
    else:
        master = logo(1024)
        print("no master logo supplied, rendering one")

    # --- hicolor icon theme -------------------------------------------------
    for s in ICON_SIZES:
        d = ensure("icons", "hicolor", f"{s}x{s}", "apps")
        # Small sizes get the drawn logo: downscaling the master muddies the A.
        src = master if s >= 128 and have_master else logo(max(s, 256))
        src.resize((s, s), Image.LANCZOS).save(os.path.join(d, "scraplinux.png"))
        mono(max(s, 64)).resize((s, s), Image.LANCZOS).save(
            os.path.join(d, "scraplinux-symbolic.png"))
    print(f"icon theme: {len(ICON_SIZES)} sizes")

    # --- primary logos ------------------------------------------------------
    p = ensure("plasma")
    (master if have_master else logo(512)).resize((512, 512), Image.LANCZOS).save(
        os.path.join(p, "scraplinux-logo.png"))
    logo(512).save(os.path.join(p, "scraplinux-logo-clean.png"))
    mono(512).save(os.path.join(p, "scraplinux-logo-white.png"))
    mono(512, colour=ICE_DARK).save(os.path.join(p, "scraplinux-logo-dark.png"))
    with open(os.path.join(p, "scraplinux-logo.svg"), "w") as f:
        f.write(SVG)
    with open(os.path.join(p, "scraplinux-logo-symbolic.svg"), "w") as f:
        f.write(SVG_MONO)

    # --- wallpapers ---------------------------------------------------------
    wp = ensure("wallpaper")
    for w, h in [(1920, 1080), (2560, 1440), (3840, 2160)]:
        bg = diagonal_gradient((w // 4, h // 4)).resize((w, h), Image.BICUBIC)
        bg = bg.filter(ImageFilter.GaussianBlur(2)).convert("RGBA")
        # A large, low-contrast watermark of the mark itself.
        mark_size = int(h * 0.62)
        mark = mono(mark_size)
        mark.putalpha(mark.getchannel("A").point(lambda a: int(a * 0.10)))
        bg.alpha_composite(mark, ((w - mark_size) // 2, (h - mark_size) // 2))
        bg.convert("RGB").save(os.path.join(wp, f"scraplinux-{w}x{h}.png"))
    print("wallpapers: 1080p, 1440p, 4K")

    # --- SDDM / login -------------------------------------------------------
    s = ensure("sddm")
    logo(256).save(os.path.join(s, "logo.png"))
    mono(256).save(os.path.join(s, "logo-white.png"))
    Image.open(os.path.join(wp, "scraplinux-1920x1080.png")).save(
        os.path.join(s, "background.png"))

    # --- Limine boot splash -------------------------------------------------
    # Limine wants a plain 640x480 or larger image for its background.
    b = ensure("limine")
    splash = diagonal_gradient((640, 480)).convert("RGBA")
    mark = mono(300)
    mark.putalpha(mark.getchannel("A").point(lambda a: int(a * 0.85)))
    splash.alpha_composite(mark, (170, 90))
    splash.convert("RGB").save(os.path.join(b, "splash.png"))
    splash.convert("RGB").resize((1920, 1080), Image.BICUBIC).save(
        os.path.join(b, "splash-1080.png"))

    # --- favicon / installer inline asset -----------------------------------
    ico = ensure("misc")
    frames = [logo(s) for s in (16, 32, 48, 64, 128, 256)]
    frames[0].save(os.path.join(ico, "scraplinux.ico"),
                   sizes=[(f.width, f.height) for f in frames],
                   append_images=frames[1:])
    with open(os.path.join(ico, "scraplinux-logo.png.b64"), "w") as f:
        f.write(base64.b64encode(
            open(os.path.join(p, "scraplinux-logo.png"), "rb").read()).decode())

    print("branding written under", HERE)


if __name__ == "__main__":
    main()
