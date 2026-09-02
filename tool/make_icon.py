#!/usr/bin/env python3
"""Generates the application icon from icons/butterfly-image.png.

The source is a 1408px square with a transparent surround. Downsampling it
directly gives a washed-out 16px icon, because at that size the wings are two
or three pixels wide and average into the background. So the artwork is
trimmed to its own alpha bounds, inset inside a dark rounded square that gives
it a consistent silhouette in a dock, and grown slightly at the small sizes
where a thinner subject would disappear.

    python3 tool/make_icon.py

Writes assets/icon/app_icon_{16,24,32,48,64,128,256,512}.png
"""

import os

from PIL import Image

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.normpath(os.path.join(HERE, "..", "icons", "butterfly-image.png"))
OUT_DIR = os.path.join(HERE, "assets", "icon")
SIZES = [16, 24, 32, 48, 64, 128, 256, 512]

SS = 4                      # supersampling factor for the plate
BASE = 512
N = BASE * SS

BG_TOP = (38, 38, 44, 255)
BG_BOTTOM = (16, 16, 20, 255)
RADIUS = 0.20               # of the plate edge
# How much of the plate the butterfly spans. Small icons get more, because a
# 16px render loses the outer wing tips to antialiasing either way.
INSET = {16: 0.94, 24: 0.92, 32: 0.90, 48: 0.88}
INSET_DEFAULT = 0.86


def rounded_rect_mask(n, radius):
    from PIL import ImageDraw
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, n - 1, n - 1], radius=radius,
                                           fill=255)
    return mask


def vertical_gradient(n, top, bottom):
    grad = Image.new("RGBA", (1, n))
    px = grad.load()
    for y in range(n):
        t = y / (n - 1)
        px[0, y] = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
    return grad.resize((n, n))


def trimmed_subject():
    """The butterfly with its transparent margin removed, kept square."""
    img = Image.open(SOURCE).convert("RGBA")
    box = img.getchannel("A").getbbox()
    if box is None:
        return img
    img = img.crop(box)
    # Pad back to square so the aspect ratio survives the resize below.
    side = max(img.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(img, ((side - img.width) // 2, (side - img.height) // 2))
    return square


def plate(subject, inset):
    img = vertical_gradient(N, BG_TOP, BG_BOTTOM)
    span = int(N * inset)
    art = subject.resize((span, span), Image.LANCZOS)
    off = (N - span) // 2
    img.alpha_composite(art, (off, off))
    img.putalpha(rounded_rect_mask(N, int(N * RADIUS)))
    return img


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    subject = trimmed_subject()
    for size in SIZES:
        master = plate(subject, INSET.get(size, INSET_DEFAULT))
        out = master.resize((size, size), Image.LANCZOS)
        path = os.path.join(OUT_DIR, f"app_icon_{size}.png")
        out.save(path)
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
