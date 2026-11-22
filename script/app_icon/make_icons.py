#!/usr/bin/env python3
"""Draws OpenArc's app icons from the mark in mark.py.

Writes the bundle icon set (the Original colors), the iOS app icon in Icon
Composer's format, one 1024 px PNG for each icon Settings offers, the iOS
alternate icons with their small pictures for the icon picker and the
widget, and the website's favicon. Needs `rsvg-convert` (Homebrew librsvg) and Pillow.

    script/app_icon/make_icons.py
"""

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import mark  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]
ICON_SET = ROOT / "Sources/Browser/Assets.xcassets/AppIcon.appiconset"
IOS_ICON = ROOT / "Sources/BrowseriOS/AppIcon.icon"
RESOURCES = ROOT / "Sources/Browser/Resources"
IOS_ASSETS = ROOT / "Sources/BrowseriOS/Assets.xcassets"
WIDGET_ASSETS = ROOT / "Sources/OpenArcWidgets/Assets.xcassets"
FAVICON = ROOT / "Website/public/favicon.svg"

# macOS icon grid: a 824 px body with a 100 px margin on a 1024 px canvas.
CANVAS, BODY, MARGIN, RADIUS = 1024, 824, 100, 185
MARK_WIDTH = 680
# A sticker's outline takes room, so its mark is drawn wider.
STICKER_WIDTH = 700
# The iOS icon's mark inside the system's rounded square, and the width of
# the white sticker outline around it, in the mark's own units.
IOS_MARK_WIDTH = 640
IOS_OUTLINE = 100


def mark_transform(width=MARK_WIDTH):
    scale = width / mark.WIDTH
    height = mark.HEIGHT * scale
    x = (CANVAS - width) / 2
    # The mark's weight sits low; lift it a little above the true center.
    y = (CANVAS - height) / 2 - 12
    return f"translate({x:.2f},{y:.2f}) scale({scale:.5f})"


def gradient(gid, stops, x1=0, y1=0, x2=0, y2=1):
    stop_tags = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in stops)
    return (
        f'<linearGradient id="{gid}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{stop_tags}</linearGradient>'
    )


# iOS draws its own rounded square over a full square icon, so its icons
# fill the canvas, with no margin, corner or shadow of their own.
FULL_BLEED = False


def body(fill, stroke="#000000", stroke_opacity=0.08):
    if FULL_BLEED:
        return f'<rect width="{CANVAS}" height="{CANVAS}" fill="{fill}"/>'
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


def sticker_mark(leg_fill, arch_fill, outline, rim_color, rim_opacity, width=STICKER_WIDTH):
    """The mark as a sticker: a white outline around both shapes, a faint rim
    around their outline, and a soft shadow under it all."""
    rim = (
        '<filter id="sticker" x="-20%" y="-20%" width="140%" height="160%">'
        '<feMorphology in="SourceAlpha" operator="dilate" radius="4" result="grown"/>'
        f'<feFlood flood-color="{rim_color}" flood-opacity="{rim_opacity}"/>'
        '<feComposite in2="grown" operator="in" result="rim"/>'
        '<feGaussianBlur in="SourceAlpha" stdDeviation="20" result="blur"/>'
        '<feOffset in="blur" dy="16" result="drop"/>'
        '<feFlood flood-color="#1B1F4A" flood-opacity="0.16"/>'
        '<feComposite in2="drop" operator="in" result="shadow"/>'
        '<feMerge><feMergeNode in="shadow"/><feMergeNode in="rim"/><feMergeNode in="SourceGraphic"/></feMerge>'
        "</filter>"
    )
    line = f'fill="#FFFFFF" stroke="#FFFFFF" stroke-width="{outline}" stroke-linejoin="round"'
    group = (
        f'<g transform="{mark_transform(width)}" filter="url(#sticker)">'
        f'<path d="{mark.leg()}" {line}/><path d="{mark.arch()}" {line}/>'
        f'<path d="{mark.leg()}" fill="{leg_fill}"/><path d="{mark.arch()}" fill="{arch_fill}"/></g>'
    )
    return rim, group


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


def original(outline=58):
    rim, group = sticker_mark("url(#leg)", "url(#arch)", outline, "#6E7487", 0.3)
    defs = (
        gradient("bg", [(0, "#FFFFFF"), (1, "#F7F8FB")])
        + gradient("leg", [(0, "#5B6CFF"), (1, "#1B26A8")], 0.2, 0, 0.6, 1)
        + gradient("arch", [(0, "#FF8A98"), (0.55, "#F2475F"), (1, "#C92A47")], 0.1, 0, 0.9, 1)
        + rim
    )
    return svg(defs, body("url(#bg)") + group)


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


def sheen():
    """The hologram's light over the top half of its body."""
    if FULL_BLEED:
        return f'<rect width="{CANVAS}" height="{CANVAS / 2}" fill="url(#sheen)" opacity="0.35"/>'
    return (
        f'<rect x="{MARGIN}" y="{MARGIN}" width="{BODY}" height="{BODY / 2}" rx="{RADIUS}" '
        'fill="url(#sheen)" opacity="0.35"/>'
    )


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
        + sheen()
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
    rim, group = sticker_mark("#3F6BF0", "#F2633F", 58, "#8A6A2A", 0.3)
    defs = gradient("bg", [(0, "#F8EBC4"), (1, "#EFDCA6")]) + rim
    return svg(defs, body("url(#bg)") + group)


def monochrome():
    content = body("#FFFFFF") + shapes('fill="#111111"', 'fill="#111111"')
    return svg("", content)


def ios_layer(name, path, stops, x1, y1, x2, y2):
    """One shape of the mark as an Icon Composer layer on the 1024 pt canvas."""
    defs = gradient(name, stops, x1, y1, x2, y2)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
        f'viewBox="0 0 {CANVAS} {CANVAS}"><defs>{defs}</defs>'
        f'<g transform="{mark_transform(IOS_MARK_WIDTH)}"><path d="{path}" fill="url(#{name})"/></g></svg>\n'
    )


def ios_outline():
    """Both shapes of the mark grown by a white sticker outline, which also
    fills the gap between them."""
    line = f'fill="#FFFFFF" stroke="#FFFFFF" stroke-width="{IOS_OUTLINE}" stroke-linejoin="round"'
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
        f'viewBox="0 0 {CANVAS} {CANVAS}"><g transform="{mark_transform(IOS_MARK_WIDTH)}">'
        f'<path d="{mark.leg()}" {line}/><path d="{mark.arch()}" {line}/></g></svg>\n'
    )


def ios_icon():
    """The iOS icon in Icon Composer's format: the arch and the leg as glass
    layers on a white sticker outline over a pale fill, so the system draws
    the dark, tinted and clear looks from them."""
    layers = {
        "outline.svg": ios_outline(),
        "arch.svg": ios_layer("arch", mark.arch(), [(0, "#FF8A98"), (0.55, "#F2475F"), (1, "#C92A47")], 0.1, 0, 0.9, 1),
        "leg.svg": ios_layer("leg", mark.leg(), [(0, "#5B6CFF"), (1, "#1B26A8")], 0.2, 0, 0.6, 1),
    }
    description = {
        "fill-specializations": [
            {"value": {"automatic-gradient": "srgb:0.94902,0.95294,0.97255,1.00000"}},
            {"appearance": "dark", "value": "automatic"},
        ],
        "groups": [
            {
                "name": "Mark",
                "layers": [
                    {"glass": True, "image-name": "arch.svg", "name": "arch"},
                    {"glass": True, "image-name": "leg.svg", "name": "leg"},
                ],
                "lighting": "individual",
                "shadow": {"kind": "layer-color", "opacity": 0.5},
                "specular": True,
                "translucency": {"enabled": True, "value": 0.2},
            },
            {
                "name": "Outline",
                "layers": [{"image-name": "outline.svg", "name": "outline"}],
                "lighting": "combined",
                "shadow": {"kind": "neutral", "opacity": 0.35},
                "specular": False,
            },
        ],
        "supported-platforms": {"squares": "shared"},
    }
    return layers, description


def write_ios_icon():
    layers, description = ios_icon()
    if IOS_ICON.exists():
        shutil.rmtree(IOS_ICON)
    assets = IOS_ICON / "Assets"
    assets.mkdir(parents=True)
    for name, content in layers.items():
        (assets / name).write_text(content)
    (IOS_ICON / "icon.json").write_text(json.dumps(description, indent=2) + "\n")


def favicon():
    """The Original icon for browser tabs: the body fills the box, without the
    shadow and the sticker's filter, which blur at 16 px."""
    defs = (
        gradient("bg", [(0, "#FFFFFF"), (1, "#F2F3F8")])
        + gradient("leg", [(0, "#5B6CFF"), (1, "#1B26A8")], 0.2, 0, 0.6, 1)
        + gradient("arch", [(0, "#FF8A98"), (0.55, "#F2475F"), (1, "#C92A47")], 0.1, 0, 0.9, 1)
    )
    outline = 'fill="#FFFFFF" stroke="#FFFFFF" stroke-width="58" stroke-linejoin="round"'
    content = (
        f'<rect x="{MARGIN}" y="{MARGIN}" width="{BODY}" height="{BODY}" rx="{RADIUS}" fill="url(#bg)"/>'
        f'<rect x="{MARGIN + 4}" y="{MARGIN + 4}" width="{BODY - 8}" height="{BODY - 8}" rx="{RADIUS - 4}" '
        'fill="none" stroke="#1B1F4A" stroke-opacity="0.12" stroke-width="8"/>'
        f'<g transform="{mark_transform(STICKER_WIDTH)}">'
        f'<path d="{mark.leg()}" {outline}/><path d="{mark.arch()}" {outline}/>'
        f'<path d="{mark.leg()}" fill="url(#leg)"/><path d="{mark.arch()}" fill="url(#arch)"/></g>'
    )
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{MARGIN} {MARGIN} {BODY} {BODY}">'
        f"<defs>{defs}</defs>{content}</svg>\n"
    )


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


# The icon picker's pictures: 64 pt at 3x.
IOS_PREVIEW_SIZE = 192


def opaque_png(source, size, destination):
    """Renders the SVG without an alpha channel, which iOS app icons may not have."""
    from PIL import Image

    render(source, size, destination)
    Image.open(destination).convert("RGB").save(destination, optimize=True)


def contents(images):
    return json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n"


def write_ios_alternates(temporary):
    """An app icon set for each alternate icon, and an image set with its
    picture for the picker, the Original's too."""
    global FULL_BLEED
    FULL_BLEED = True
    try:
        for name, draw in VARIANTS.items():
            source = pathlib.Path(temporary) / f"ios-{name}.svg"
            source.write_text(draw())
            title = name.capitalize()
            preview = IOS_ASSETS / f"AppIconPreview-{title}.imageset"
            preview.mkdir(parents=True, exist_ok=True)
            opaque_png(source, IOS_PREVIEW_SIZE, preview / "preview.png")
            (preview / "Contents.json").write_text(
                contents([{"filename": "preview.png", "idiom": "universal"}])
            )
            if name == "original":
                # The Home Screen widget shows the Original beside its search field.
                mark = WIDGET_ASSETS / "AppMark.imageset"
                mark.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(preview / "preview.png", mark / "mark.png")
                (mark / "Contents.json").write_text(contents([{"filename": "mark.png", "idiom": "universal"}]))
                continue
            icon_set = IOS_ASSETS / f"AppIcon-{title}.appiconset"
            icon_set.mkdir(parents=True, exist_ok=True)
            opaque_png(source, CANVAS, icon_set / "icon.png")
            (icon_set / "Contents.json").write_text(
                contents([{"filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}])
            )
    finally:
        FULL_BLEED = False


def main():
    FAVICON.write_text(favicon())
    write_ios_icon()
    with tempfile.TemporaryDirectory() as temporary:
        for name, draw in VARIANTS.items():
            source = pathlib.Path(temporary) / f"{name}.svg"
            source.write_text(draw())
            if name == "original":
                for size in ICON_SET_SIZES:
                    render(source, size, ICON_SET / f"icon_{size}.png")
            else:
                render(source, CANVAS, RESOURCES / f"openarc-icon-{name}.png")
        write_ios_alternates(temporary)


if __name__ == "__main__":
    main()
