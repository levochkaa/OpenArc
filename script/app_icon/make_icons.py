#!/usr/bin/env python3
"""Draws OpenArc's app icons from the mark in mark.py.

Writes the bundle icon set (the Original colors) and one 1024 px PNG for each
icon Settings offers. Needs `rsvg-convert` (Homebrew librsvg).

    script/app_icon/make_icons.py
"""

import pathlib
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import mark  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]
ICON_SET = ROOT / "Sources/Browser/Assets.xcassets/AppIcon.appiconset"
RESOURCES = ROOT / "Sources/Browser/Resources"

# macOS icon grid: a 824 px body with a 100 px margin on a 1024 px canvas.
CANVAS, BODY, MARGIN, RADIUS = 1024, 824, 100, 185
MARK_WIDTH = 640


def mark_transform():
    scale = MARK_WIDTH / mark.WIDTH
    height = mark.HEIGHT * scale
    x = (CANVAS - MARK_WIDTH) / 2
    # The mark's weight sits low; lift it a little above the true center.
    y = (CANVAS - height) / 2 - 12
    return f"translate({x:.2f},{y:.2f}) scale({scale:.5f})"


def gradient(gid, stops, x1=0, y1=0, x2=0, y2=1):
    stop_tags = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in stops)
    return (
        f'<linearGradient id="{gid}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{stop_tags}</linearGradient>'
    )


def body(fill, stroke="#000000", stroke_opacity=0.08):
    return (
        f'<rect x="{MARGIN}" y="{MARGIN}" width="{BODY}" height="{BODY}" rx="{RADIUS}" fill="{fill}" '
        f'filter="url(#body-shadow)"/>'
        f'<rect x="{MARGIN + 1}" y="{MARGIN + 1}" width="{BODY - 2}" height="{BODY - 2}" rx="{RADIUS - 1}" '
        f'fill="none" stroke="{stroke}" stroke-opacity="{stroke_opacity}" stroke-width="2"/>'
    )


BODY_SHADOW = (
    '<filter id="body-shadow" x="-10%" y="-10%" width="120%" height="125%">'
    '<feDropShadow dx="0" dy="10" stdDeviation="10" flood-color="#000" flood-opacity="0.3"/></filter>'
)


def shapes(leg, arch, extra=""):
    return f'<g transform="{mark_transform()}">{extra}<path d="{mark.leg()}" {leg}/><path d="{mark.arch()}" {arch}/></g>'


def svg(defs, content):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
        f'viewBox="0 0 {CANVAS} {CANVAS}"><defs>{BODY_SHADOW}{defs}</defs>{content}</svg>'
    )


def glow(fid, color, deviation, opacity):
    return (
        f'<filter id="{fid}" x="-30%" y="-30%" width="160%" height="160%">'
        f'<feGaussianBlur in="SourceAlpha" stdDeviation="{deviation}" result="blur"/>'
        f'<feFlood flood-color="{color}" flood-opacity="{opacity}"/>'
        '<feComposite in2="blur" operator="in" result="glow"/>'
        '<feMerge><feMergeNode in="glow"/><feMergeNode in="SourceGraphic"/></feMerge></filter>'
    )


def soft_shadow(fid, color, opacity, dy=14, deviation=16):
    return (
        f'<filter id="{fid}" x="-30%" y="-30%" width="160%" height="170%">'
        f'<feDropShadow dx="0" dy="{dy}" stdDeviation="{deviation}" flood-color="{color}" '
        f'flood-opacity="{opacity}"/></filter>'
    )


def original():
    defs = (
        gradient("bg", [(0, "#FFFFFF"), (1, "#EEF0F6")])
        + gradient("leg", [(0, "#5B6CFF"), (1, "#1B26A8")], 0.2, 0, 0.6, 1)
        + gradient("arch", [(0, "#FF8A98"), (0.55, "#F2475F"), (1, "#C92A47")], 0.1, 0, 0.9, 1)
        + soft_shadow("lift", "#1B1F4A", 0.22)
    )
    content = body("url(#bg)") + shapes(
        'fill="url(#leg)" filter="url(#lift)"', 'fill="url(#arch)" fill-opacity="0.96" filter="url(#lift)"'
    )
    return svg(defs, content)


def candy():
    defs = (
        gradient("bg", [(0, "#FBE3EC"), (1, "#E7D2F3")])
        + gradient("leg", [(0, "#8EA0FF"), (1, "#5B5FEF")])
        + gradient("arch", [(0, "#FFB0BE"), (1, "#F2648C")], 0, 0, 1, 1)
        + glow("halo", "#FFFFFF", 10, 0.9)
    )
    outline = 'stroke="#FFFFFF" stroke-width="22" stroke-linejoin="round"'
    content = body("url(#bg)", "#FFFFFF", 0.5) + shapes(
        f'fill="url(#leg)" {outline} paint-order="stroke" filter="url(#halo)"',
        f'fill="url(#arch)" {outline} paint-order="stroke" filter="url(#halo)"',
    )
    return svg(defs, content)


def neon():
    defs = (
        gradient("bg", [(0, "#1B0B3D"), (1, "#3A0D58")])
        + glow("glow-pink", "#FF4FD8", 14, 0.9)
        + glow("glow-violet", "#8F7BFF", 14, 0.9)
    )
    line = 'fill="none" stroke-width="26" stroke-linejoin="round"'
    content = body("url(#bg)", "#FFFFFF", 0.1) + shapes(
        f'{line} stroke="#B6A8FF" filter="url(#glow-violet)"',
        f'{line} stroke="#FF8BE6" filter="url(#glow-pink)"',
    )
    return svg(defs, content)


def hologram():
    defs = (
        gradient(
            "bg",
            [(0, "#C9F5EC"), (0.35, "#E4D9FF"), (0.65, "#FFD9EC"), (1, "#D3E9FF")],
            0, 0, 1, 1,
        )
        + gradient("sheen", [(0, "#FFFFFF"), (1, "#FFFFFF00")], 0, 0, 0, 1)
    )
    line = 'fill="#FFFFFF" fill-opacity="0.35" stroke="#1E2230" stroke-width="26" stroke-linejoin="round"'
    content = (
        body("url(#bg)", "#FFFFFF", 0.6)
        + f'<rect x="{MARGIN}" y="{MARGIN}" width="{BODY}" height="{BODY / 2}" rx="{RADIUS}" '
        'fill="url(#sheen)" opacity="0.35"/>'
        + shapes(line, line)
    )
    return svg(defs, content)


def sunset():
    defs = (
        gradient("bg", [(0, "#1D1236"), (1, "#2C1450")])
        + gradient("leg", [(0, "#FFC15E"), (1, "#FF5E7E")])
        + gradient("arch", [(0, "#8B6CFF"), (1, "#E64FC8")], 0, 0, 1, 1)
        + glow("glow", "#B45CFF", 22, 0.55)
    )
    content = body("url(#bg)", "#FFFFFF", 0.1) + shapes(
        'fill="url(#leg)" filter="url(#glow)"', 'fill="url(#arch)" fill-opacity="0.95" filter="url(#glow)"'
    )
    return svg(defs, content)


def sticker():
    defs = gradient("bg", [(0, "#F8EBC4"), (1, "#EFDCA6")]) + soft_shadow("lift", "#6B4E12", 0.25, 8, 8)
    outline = 'stroke="#FFFFFF" stroke-width="26" stroke-linejoin="round" paint-order="stroke"'
    content = body("url(#bg)") + shapes(
        f'fill="#3F6BF0" {outline} filter="url(#lift)"', f'fill="#F2633F" {outline} filter="url(#lift)"'
    )
    return svg(defs, content)


def monochrome():
    content = body("#FFFFFF") + shapes('fill="#111111"', 'fill="#111111"')
    return svg("", content)


VARIANTS = {
    "original": original,
    "candy": candy,
    "neon": neon,
    "hologram": hologram,
    "sunset": sunset,
    "sticker": sticker,
    "monochrome": monochrome,
}

ICON_SET_SIZES = [16, 32, 64, 128, 256, 512, 1024]


def render(source, size, destination):
    subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), source, "-o", str(destination)], check=True
    )


def main():
    with tempfile.TemporaryDirectory() as temporary:
        for name, draw in VARIANTS.items():
            source = pathlib.Path(temporary) / f"{name}.svg"
            source.write_text(draw())
            if name == "original":
                for size in ICON_SET_SIZES:
                    render(source, size, ICON_SET / f"icon_{size}.png")
            else:
                render(source, CANVAS, RESOURCES / f"openarc-icon-{name}.png")


if __name__ == "__main__":
    main()
