#!/usr/bin/env python3
"""Render docs/assets/cover.png for the README.

Requires Pillow + numpy + rsvg-convert (the icon source is an SVG).
Run from anywhere: the script resolves the repo root itself.
"""
from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs" / "assets" / "cover.png"
ICON_SVG = ROOT / "packaging" / "icons" / "deepseek-harness.svg"

W, H = 1600, 640
S = 2  # draw at 2x, downsample for clean text
CW, CH = W * S, H * S

F_LATIN_BOLD = "/usr/share/fonts/noto/NotoSans-Bold.ttf"
F_LATIN = "/usr/share/fonts/noto/NotoSans-Regular.ttf"
F_CJK_BOLD = "/usr/share/fonts/noto-cjk/NotoSansCJK-Bold.ttc"
F_CJK = "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc"
F_MONO = "/usr/share/fonts/noto/NotoSansMono-Regular.ttf"
F_MONO_BOLD = "/usr/share/fonts/noto/NotoSansMono-Bold.ttf"


def font(path: str, size: int, index: int | None = None) -> ImageFont.FreeTypeFont:
    if index is None:
        return ImageFont.truetype(path, size)
    return ImageFont.truetype(path, size, index=index)


def main() -> None:
    # --- background: vertical gradient + soft blue glow + faint grid -------
    top = np.array([5, 8, 16], dtype=np.float32)
    bottom = np.array([10, 20, 38], dtype=np.float32)
    t = np.linspace(0.0, 1.0, CH, dtype=np.float32)[:, None, None]
    arr = (top * (1 - t) + bottom * t).astype(np.uint8)
    arr = np.repeat(arr, CW, axis=1)
    img = Image.fromarray(arr, "RGB").convert("RGBA")

    glow = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([CW * 0.05, CH * 0.05, CW * 0.62, CH * 1.25], fill=(35, 65, 255, 52))
    gd.ellipse([CW * 0.02, CH * 0.25, CW * 0.30, CH * 1.10], fill=(40, 85, 255, 70))
    glow = glow.filter(ImageFilter.GaussianBlur(170))
    img = Image.alpha_composite(img, glow)

    grid = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grid)
    step = 48 * S
    for x in range(0, CW, step):
        gd.line([(x, 0), (x, CH)], fill=(120, 150, 220, 9))
    for y in range(0, CH, step):
        gd.line([(0, y), (CW, y)], fill=(120, 150, 220, 9))
    img = Image.alpha_composite(img, grid)

    beam = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
    bd = ImageDraw.Draw(beam)
    bd.polygon(
        [(0, CH), (CW * 0.34, 0), (CW * 0.47, 0), (CW * 0.10, CH)],
        fill=(255, 255, 255, 5),
    )
    img = Image.alpha_composite(img, beam)

    draw = ImageDraw.Draw(img)

    # --- brand icon ---------------------------------------------------------
    icon_x, icon_y, icon_size = 220, 360, 500
    with tempfile.TemporaryDirectory() as td:
        rendered = Path(td) / "icon.png"
        subprocess.run(
            ["rsvg-convert", "-w", "1024", "-h", "1024", "-o", str(rendered), str(ICON_SVG)],
            check=True,
        )
        icon = Image.open(rendered).convert("RGBA").resize((icon_size, icon_size), Image.LANCZOS)

    halo = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
    hd = ImageDraw.Draw(halo)
    hd.rounded_rectangle(
        [icon_x - 40, icon_y - 40, icon_x + icon_size + 40, icon_y + icon_size + 40],
        radius=90,
        fill=(50, 95, 255, 90),
    )
    halo = halo.filter(ImageFilter.GaussianBlur(90))
    img = Image.alpha_composite(img, halo)
    draw = ImageDraw.Draw(img)

    shadow = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(
        [icon_x + 12, icon_y + 24, icon_x + icon_size + 12, icon_y + icon_size + 24],
        radius=58,
        fill=(0, 0, 0, 150),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(34))
    img = Image.alpha_composite(img, shadow)
    img.alpha_composite(icon, (icon_x, icon_y))
    draw = ImageDraw.Draw(img)

    # --- left text block ----------------------------------------------------
    text_x = 840

    def spaced_text(x: int, y: int, text: str, fnt, fill, spacing: int) -> None:
        cx = x
        for ch in text:
            draw.text((cx, y), ch, font=fnt, fill=fill)
            cx += int(draw.textlength(ch, font=fnt)) + spacing

    f_overline = font(F_LATIN_BOLD, 38)
    spaced_text(text_x, 272, "ARCH LINUX · WAYLAND", f_overline, (127, 166, 255, 255), 6)

    f_h1 = font(F_LATIN_BOLD, 144)
    h1 = "DeepSeek Harness"
    while draw.textlength(h1, font=f_h1) > 1880:
        f_h1 = font(F_LATIN_BOLD, f_h1.size - 6)
    draw.text((text_x - 4, 326), h1, font=f_h1, fill=(244, 248, 255, 255))

    draw.rounded_rectangle([text_x, 532, text_x + 170, 540], radius=4, fill=(77, 107, 254, 255))

    f_sub = font(F_CJK, 56, index=2)
    draw.text((text_x, 574), "原生 Wayland · NVIDIA 硬渲染", font=f_sub, fill=(190, 202, 228, 255))

    f_desc = font(F_CJK, 40, index=2)
    draw.text(
        (text_x, 660),
        "跟踪上游 master · 最小补丁 · dsh-git 式滚动构建",
        font=f_desc,
        fill=(125, 139, 171, 255),
    )

    # --- pills --------------------------------------------------------------
    f_pill = font(F_LATIN_BOLD, 28)
    pill_y = 780
    pill_h = 72
    pill_x = text_x
    pills = [
        ("rolling", (28, 56, 128, 220), (220, 232, 255, 255)),
        ("x86_64", (18, 31, 56, 220), (175, 192, 224, 255)),
        ("非官方构建", (18, 31, 56, 220), (150, 166, 198, 255)),
    ]
    for label, fill, fg in pills:
        fnt = f_pill if label != "非官方构建" else font(F_CJK, 28, index=2)
        tw = int(draw.textlength(label, font=fnt))
        pw = tw + 56
        draw.rounded_rectangle(
            [pill_x, pill_y, pill_x + pw, pill_y + pill_h],
            radius=36,
            fill=fill,
            outline=(44, 64, 106, 255),
            width=2,
        )
        draw.text((pill_x + 28, pill_y + (pill_h - fnt.size) // 2 - 2), label, font=fnt, fill=fg)
        pill_x += pw + 20

    # --- terminal card ------------------------------------------------------
    card_x, card_y, card_w, card_h = 2280, 336, 720, 632
    card_shadow = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
    cs = ImageDraw.Draw(card_shadow)
    cs.rounded_rectangle(
        [card_x + 18, card_y + 26, card_x + card_w + 18, card_y + card_h + 26],
        radius=34,
        fill=(0, 0, 0, 140),
    )
    card_shadow = card_shadow.filter(ImageFilter.GaussianBlur(36))
    img = Image.alpha_composite(img, card_shadow)
    draw = ImageDraw.Draw(img)

    draw.rounded_rectangle(
        [card_x, card_y, card_x + card_w, card_y + card_h],
        radius=30,
        fill=(9, 15, 28, 238),
        outline=(39, 60, 104, 255),
        width=2,
    )
    # top bar
    for i, color in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        cx = card_x + 42 + i * 30
        draw.ellipse([cx - 9, card_y + 34, cx + 9, card_y + 52], fill=(*color, 255))
    draw.line([(card_x + 24, card_y + 78), (card_x + card_w - 24, card_y + 78)], fill=(30, 47, 82, 255), width=2)

    f_mono = font(F_MONO, 30)
    f_mono_b = font(F_MONO_BOLD, 30)
    line_y = card_y + 116
    lh = 58
    x0 = card_x + 44

    def cmd(y: int, prompt: str, command: str) -> None:
        draw.text((x0, y), prompt, font=f_mono_b, fill=(108, 140, 255, 255))
        draw.text((x0 + 34, y), command, font=f_mono, fill=(218, 228, 248, 255))

    cmd(line_y, "$", "pacman -Syu")
    draw.text((x0, line_y + lh), "::", font=f_mono, fill=(86, 105, 145, 255))
    draw.text((x0 + 44, line_y + lh), "dsh-git rolling", font=f_mono, fill=(138, 155, 188, 255))
    cmd(line_y + lh * 2, "$", "dsh-wayland-doctor")

    def check(y: int, text: str) -> None:
        cx, cy = x0 + 10, y + 16
        draw.line([(cx - 2, cy), (cx + 8, cy + 11), (cx + 25, cy - 11)], fill=(94, 224, 160, 255), width=5)
        draw.text((x0 + 54, y), text, font=f_mono, fill=(188, 214, 198, 255))

    check(line_y + lh * 3, "native Wayland")
    check(line_y + lh * 4, "NVIDIA GPU")
    check(line_y + lh * 5, "GPU compositing")

    draw.text(
        (card_x + 44, card_y + card_h - 48),
        "unofficial build · MIT",
        font=font(F_LATIN, 24),
        fill=(76, 92, 124, 255),
    )

    # --- footer URL ---------------------------------------------------------
    draw.text(
        (text_x, 1148),
        "github.com/Moritz230127/deepseek-harness-desktop-wayland",
        font=font(F_LATIN, 28),
        fill=(80, 96, 128, 255),
    )

    # --- downsample + save --------------------------------------------------
    out = img.convert("RGB").resize((W, H), Image.LANCZOS)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    out.save(OUT, "PNG", optimize=True)
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
