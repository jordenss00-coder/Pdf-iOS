"""Uygulama ikonunu üretir: masaüstündeki marka işareti (çember + artı), camgöbeği zemin.

App Store ikonu 1024×1024 olmalı ve saydamlık içermemeli. Gerekenler: Pillow.
"""
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
SIZE = 1024
SCALE = 4  # Kenar yumuşatma için büyük çizip küçült.
TOP, BOTTOM = (0x00, 0xA3, 0xE0), (0x00, 0x6E, 0xA3)  # #0093d0 çevresinde dikey geçiş


def main():
    size = SIZE * SCALE
    image = Image.new("RGB", (size, size))
    draw = ImageDraw.Draw(image)
    for y in range(size):
        t = y / (size - 1)
        draw.line([(0, y), (size, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))

    # Masaüstündeki 32 birimlik SVG işaretinin ölçüleriyle (r=8.5, çizgiler 1.5..30.5); çizgi ikon boyutunda daha ince.
    unit = size * 0.7 / 29
    center = size / 2
    stroke = round(1.4 * unit)
    radius = 8.5 * unit
    reach = 14.5 * unit
    white = (255, 255, 255)
    draw.ellipse([center - radius, center - radius, center + radius, center + radius], outline=white, width=stroke)
    draw.line([(center, center - reach), (center, center + reach)], fill=white, width=stroke)
    draw.line([(center - reach, center), (center + reach, center)], fill=white, width=stroke)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    image.resize((SIZE, SIZE), Image.LANCZOS).save(OUT, optimize=True)


if __name__ == "__main__":
    main()
