#!/usr/bin/env python3
"""Generate Veldmuis theme artifacts from packages/veldmuis-branding/palette/veldmuis.palette.

Generated files:
  packages/veldmuis-branding/colors/Veldmuis.colors
  packages/veldmuis-branding/gtk/gtk-3.0.css
  packages/veldmuis-branding/gtk/gtk-4.0.css
  packages/veldmuis-branding/plasma-theme/colors
  packages/veldmuis-branding/plasma-theme/plasmarc
  packages/veldmuis-branding/plasma-theme/metadata.json

Usage:
  development/generate-brand-palette.py            # write generated files
  development/generate-brand-palette.py --check    # exit 1 if any file is stale
  development/generate-brand-palette.py --report    # print palette and contrast table
  development/generate-brand-palette.py --out DIR   # write into DIR instead of the repo

Shades that are not in the palette (a border that clears 3:1, disabled text,
selection-inactive text) are derived here so they cannot drift.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PALETTE_PATH = REPO / "packages/veldmuis-branding/palette/veldmuis.palette"

SCHEME_OUT = "packages/veldmuis-branding/colors/Veldmuis.colors"
GTK3_OUT = "packages/veldmuis-branding/gtk/theme/gtk-3.0/gtk.css"
GTK4_OUT = "packages/veldmuis-branding/gtk/theme/gtk-4.0/gtk.css"
THEME_DIR = "packages/veldmuis-branding/plasma-theme"
QSS_TEMPLATE = "packages/veldmuis-calamares-config/branding/veldmuis/stylesheet.qss.in"
QSS_OUT = "packages/veldmuis-calamares-config/branding/veldmuis/stylesheet.qss"
KDEGLOBALS = "packages/veldmuis-branding/kdeglobals"

BREEZE_GTK_SOURCE = "/usr/share/themes/Breeze-Dark"


# --- colour math -----------------------------------------------------------


def parse_palette(path: Path) -> dict[str, str]:
    palette: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if not key or not value.startswith("#") or len(value) != 7:
            raise SystemExit(f"{path}: bad palette line: {raw!r}")
        palette[key] = value.lower()
    missing = {
        "surface-deep",
        "surface-base",
        "panel",
        "panel-raised",
        "line",
        "line-soft",
        "text",
        "muted",
        "muted-dim",
        "accent",
        "accent-bright",
        "accent-ink",
        "positive",
        "warning",
        "negative",
        "info",
    } - palette.keys()
    if missing:
        raise SystemExit(f"{path}: missing keys: {', '.join(sorted(missing))}")
    return palette


def rgb(hex_colour: str) -> tuple[float, float, float]:
    value = hex_colour.lstrip("#")
    return tuple(int(value[i : i + 2], 16) / 255 for i in (0, 2, 4))  # type: ignore[return-value]


def to_hex(channels: tuple[float, float, float]) -> str:
    return "#" + "".join(f"{round(max(0.0, min(1.0, c)) * 255):02x}" for c in channels)


def encode(value: float) -> float:
    return value * 12.92 if value <= 0.0031308 else 1.055 * value ** (1 / 2.4) - 0.055


def decode(value: float) -> float:
    return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4


def luminance(hex_colour: str) -> float:
    r, g, b = (decode(c) for c in rgb(hex_colour))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a: str, b: str) -> float:
    la, lb = luminance(a), luminance(b)
    if la < lb:
        la, lb = lb, la
    return (la + 0.05) / (lb + 0.05)


def mix(a: str, b: str, t: float) -> str:
    """Linear mix of a and b; t=0 is a, t=1 is b."""
    return to_hex(tuple(x + (y - x) * t for x, y in zip(rgb(a), rgb(b))))  # type: ignore[arg-type]


def lift(colour: str, background: str, target: float) -> str:
    """Brighten colour in linear space, preserving hue ratios, until contrast(colour, background) >= target."""
    if contrast(colour, background) >= target:
        return colour
    base = [decode(c) for c in rgb(colour)]
    low, high = 1.0, 64.0
    best = to_hex(tuple(encode(min(1.0, c)) for c in base))  # type: ignore[arg-type]
    for _ in range(40):
        scale = (low + high) / 2
        candidate = to_hex(tuple(encode(min(1.0, c * scale)) for c in base))  # type: ignore[arg-type]
        if contrast(candidate, background) >= target:
            best, high = candidate, scale
        else:
            low = scale
    return best


def dim(fg: str, bg: str, amount: float) -> str:
    """Pull fg toward bg by amount."""
    return mix(fg, bg, amount)


def kcfg(colour: str) -> str:
    r, g, b = (round(c * 255) for c in rgb(colour))
    return f"{r},{g},{b}"


# --- palette expansion -----------------------------------------------------


def derive(pal: dict[str, str]) -> dict[str, str]:
    lines = {
        # A hairline that is only decorative, plus a border that clears 3:1 for
        # controls where the border is the only affordance (WCAG 1.4.11).
        "line": pal["line"],
        "line-strong": lift(pal["line"], pal["panel"], 3.0),
        # Disabled text and inactive selection text.
        "disabled": mix(pal["text"], pal["panel"], 0.55),
        "selection-inactive": mix(pal["accent-ink"], pal["accent"], 0.28),
        "accent-dim": mix(pal["accent"], pal["accent-ink"], 0.12),
        "visited": "#c79ae0",
        "selection-negative": mix(pal["negative"], pal["accent-ink"], 0.62),
        "selection-positive": mix(pal["positive"], pal["accent-ink"], 0.62),
        "selection-neutral": mix(pal["warning"], pal["accent-ink"], 0.62),
    }
    return {**pal, **lines}


# --- Plasma colour scheme --------------------------------------------------


def colours_scheme(pal: dict[str, str]) -> str:
    text = pal["text"]
    muted = pal["muted"]
    dim_text = pal["muted-dim"]
    accent = pal["accent"]
    accent_bright = pal["accent-bright"]
    ink = pal["accent-ink"]

    def group(background: str, alternate: str, *, fg: str = text, inactive: str = muted,
              active: str = accent_bright, link: str = pal["info"],
              visited: str = pal["visited"], focus: str = accent,
              hover: str = accent_bright) -> list[str]:
        return [
            f"BackgroundAlternate={kcfg(alternate)}",
            f"BackgroundNormal={kcfg(background)}",
            f"DecorationFocus={kcfg(focus)}",
            f"DecorationHover={kcfg(hover)}",
            f"ForegroundActive={kcfg(active)}",
            f"ForegroundInactive={kcfg(inactive)}",
            f"ForegroundLink={kcfg(link)}",
            f"ForegroundNegative={kcfg(pal['negative'])}",
            f"ForegroundNeutral={kcfg(pal['warning'])}",
            f"ForegroundNormal={kcfg(fg)}",
            f"ForegroundPositive={kcfg(pal['positive'])}",
            f"ForegroundVisited={kcfg(visited)}",
        ]

    def section(name: str, entries: list[str]) -> list[str]:
        return [f"[{name}]", *entries, ""]

    out: list[str] = [
        "# Generated by development/generate-brand-palette.py from",
        "# packages/veldmuis-branding/palette/veldmuis.palette. Do not edit.",
        "#",
        "# SPDX-FileCopyrightText: Veldmuis Linux",
        "# SPDX-FileCopyrightText: KDE Visual Design Group (Breeze Dark baseline)",
        "# SPDX-License-Identifier: LGPL-2.0-or-later",
        "",
    ]

    out += section(
        "ColorEffects:Disabled",
        [
            f"Color={kcfg(pal['line-soft'])}",
            "ColorAmount=0",
            "ColorEffect=0",
            "ContrastAmount=0.65",
            "ContrastEffect=1",
            "IntensityAmount=0.1",
            "IntensityEffect=2",
        ],
    )
    out += section(
        "ColorEffects:Inactive",
        [
            "ChangeSelectionColor=true",
            f"Color={kcfg(pal['muted-dim'])}",
            "ColorAmount=0.025",
            "ColorEffect=2",
            "ContrastAmount=0.1",
            "ContrastEffect=2",
            "Enable=false",
            "IntensityAmount=0",
            "IntensityEffect=0",
        ],
    )

    out += section("Colors:Button", group(pal["panel"], pal["panel-raised"]))
    out += section(
        "Colors:Complementary",
        group(pal["panel-raised"], pal["panel"]),
    )
    out += section("Colors:Header", group(pal["panel"], pal["surface-base"]))
    out += section(
        "Colors:Header][Inactive",
        group(pal["panel"], pal["surface-base"], fg=muted, inactive=dim_text, active=muted),
    )
    out += section(
        "Colors:Selection",
        [
            f"BackgroundAlternate={kcfg(pal['accent-dim'])}",
            f"BackgroundNormal={kcfg(accent)}",
            f"DecorationFocus={kcfg(accent_bright)}",
            f"DecorationHover={kcfg(accent_bright)}",
            f"ForegroundActive={kcfg(ink)}",
            f"ForegroundInactive={kcfg(pal['selection-inactive'])}",
            f"ForegroundLink={kcfg(ink)}",
            f"ForegroundNegative={kcfg(pal['selection-negative'])}",
            f"ForegroundNeutral={kcfg(pal['selection-neutral'])}",
            f"ForegroundNormal={kcfg(ink)}",
            f"ForegroundPositive={kcfg(pal['selection-positive'])}",
            f"ForegroundVisited={kcfg(ink)}",
        ],
    )
    out += section("Colors:Tooltip", group(pal["panel-raised"], pal["panel"]))
    out += section("Colors:View", group(pal["surface-deep"], pal["surface-base"], inactive=dim_text))
    out += section("Colors:Window", group(pal["surface-base"], pal["panel"]))

    out += section(
        "General",
        [
            "ColorScheme=Veldmuis",
            "Name=Veldmuis",
            "shadeSortColumn=true",
        ],
    )
    out += section("KDE", ["contrast=4"])
    out += section(
        "WM",
        [
            f"activeBackground={kcfg(pal['panel-raised'])}",
            f"activeBlend={kcfg(accent_bright)}",
            f"activeForeground={kcfg(text)}",
            f"inactiveBackground={kcfg(pal['panel'])}",
            f"inactiveBlend={kcfg(muted)}",
            f"inactiveForeground={kcfg(muted)}",
        ],
    )
    return "\n".join(out).rstrip() + "\n"


# --- GTK -------------------------------------------------------------------


def gtk_css(pal: dict[str, str], gtk_version: int) -> str:
    border = pal["line-strong"]
    pairs = {
        "theme_fg_color": pal["text"],
        "theme_text_color": pal["text"],
        "theme_bg_color": pal["panel"],
        "theme_base_color": pal["surface-deep"],
        "theme_selected_bg_color": pal["accent"],
        "theme_selected_fg_color": pal["accent-ink"],
        "theme_unfocused_fg_color": pal["muted"],
        "theme_unfocused_text_color": pal["muted"],
        "theme_unfocused_bg_color": pal["panel"],
        "theme_unfocused_base_color": pal["surface-base"],
        "theme_unfocused_selected_bg_color": pal["accent-dim"],
        "theme_unfocused_selected_fg_color": pal["accent-ink"],
        "theme_unfocused_selected_bg_color_alt": pal["accent-dim"],
        "theme_view_hover_decoration_color": pal["accent"],
        "theme_view_active_decoration_color": pal["accent-bright"],
        "theme_hovering_selected_bg_color": pal["accent-bright"],
        "theme_button_background_normal": pal["panel-raised"],
        "theme_button_foreground_normal": pal["text"],
        "theme_button_foreground_active": pal["accent-ink"],
        "theme_button_decoration_focus": pal["accent"],
        "theme_button_decoration_hover": pal["accent-bright"],
        "theme_button_background_insensitive": pal["panel"],
        "theme_button_decoration_hover_insensitive": pal["line-soft"],
        "theme_button_decoration_focus_insensitive": pal["line-soft"],
        "borders": border,
        "unfocused_borders": dim(border, pal["panel"], 0.45),
        "insensitive_borders": pal["line-soft"],
        "unfocused_insensitive_borders": pal["line-soft"],
        "insensitive_bg_color": pal["panel"],
        "insensitive_base_color": pal["surface-base"],
        "insensitive_fg_color": pal["disabled"],
        "insensitive_base_fg_color": pal["disabled"],
        "insensitive_selected_bg_color": pal["panel-raised"],
        "insensitive_selected_fg_color": pal["disabled"],
        "insensitive_unfocused_bg_color": pal["panel"],
        "insensitive_unfocused_fg_color": pal["disabled"],
        "insensitive_unfocused_selected_bg_color": pal["panel-raised"],
        "insensitive_unfocused_selected_fg_color": pal["disabled"],
        "content_view_bg": pal["surface-deep"],
        # Titlebars and headers are drawn from their own variables, not theme_bg_color.
        "theme_titlebar_background": pal["panel-raised"],
        "theme_titlebar_background_backdrop": pal["panel"],
        "theme_titlebar_background_light": mix(pal["panel-raised"], pal["text"], 0.08),
        "theme_titlebar_foreground": pal["text"],
        "theme_titlebar_foreground_backdrop": pal["muted"],
        "theme_titlebar_foreground_insensitive": pal["disabled"],
        "theme_header_background": pal["panel-raised"],
        "theme_header_background_backdrop": pal["panel"],
        "theme_button_background_backdrop": pal["panel"],
        "theme_button_background_backdrop_insensitive": pal["panel"],
        "theme_button_decoration_focus_backdrop": dim(border, pal["panel"], 0.35),
        "theme_button_foreground_backdrop": pal["muted"],
        "theme_button_foreground_backdrop_insensitive": pal["disabled"],
        "theme_button_foreground_insensitive": pal["disabled"],
        "theme_button_foreground_active_insensitive": pal["disabled"],
        "theme_unfocused_view_bg_color": pal["surface-base"],
        "theme_unfocused_view_text_color": pal["muted"],
        "tooltip_background": pal["panel-raised"],
        "tooltip_text": pal["text"],
        "tooltip_border": border,
        "unfocused_insensitive_color": pal["line-soft"],
        "error_color_backdrop": dim(pal["negative"], pal["panel"], 0.35),
        "warning_color_backdrop": dim(pal["warning"], pal["panel"], 0.35),
        "success_color_backdrop": dim(pal["positive"], pal["panel"], 0.35),
        "warning_color_insensitive": dim(pal["warning"], pal["panel"], 0.55),
        "warning_color_insensitive_backdrop": dim(pal["warning"], pal["panel"], 0.7),
        "print_paper_backdrop": pal["text"],
        "link_color": pal["info"],
        "link_visited_color": pal["visited"],
        "error_color": pal["negative"],
        "warning_color": pal["warning"],
        "success_color": pal["positive"],
    }

    header = [
        "/* Generated by development/generate-brand-palette.py from",
        " * packages/veldmuis-branding/palette/veldmuis.palette. Do not edit.",
        " *",
        " * Installed as /usr/share/themes/Veldmuis and selected through",
        f" * /etc/xdg/gtk-{gtk_version}.0/settings.ini. It imports Breeze-Dark and then",
        " * overrides its palette; GTK 3 and 4 do not read a system wide",
        " * /etc/gtk-*.0/gtk.css, so a named theme is the mechanism that works.",
        " * Breeze GTK names its own palette variables with a _breeze suffix, so",
        " * both the prefixed and the generic names are set.",
        " *",
        " * SPDX-FileCopyrightText: Veldmuis Linux",
        " * SPDX-License-Identifier: MIT",
        " */",
        "",
        f'@import url("file://{BREEZE_GTK_SOURCE}/gtk-{gtk_version}.0/gtk.css");',
        "",
    ]
    body: list[str] = []
    for name, value in pairs.items():
        body.append(f"@define-color {name} {value};")
        body.append(f"@define-color {name}_breeze {value};")
    return "\n".join(header + body).rstrip() + "\n"


# --- Plasma desktop theme --------------------------------------------------

THEME_METADATA = {
    "KPackageStructure": "Plasma/DesktopTheme",
    "KPlugin": {
        "Authors": [{"Name": "Veldmuis Linux"}],
        "Category": "",
        "Description": "Breeze desktop theme with the Veldmuis palette",
        "Id": "Veldmuis",
        "License": "LGPL-2.0-or-later",
        "Name": "Veldmuis",
        "Version": "1.0",
    },
    "X-Plasma-API": "5.0",
}

THEME_PLASMARC = """\
[Wallpaper]
defaultWallpaperTheme=Next
defaultFileSuffix=.png
defaultWidth=1920
defaultHeight=1080

[AdaptiveTransparency]
enabled=true
"""


def theme_metadata() -> str:
    return json.dumps(THEME_METADATA, indent=4, ensure_ascii=False) + "\n"


# --- Calamares stylesheet --------------------------------------------------


def render_qss(pal: dict[str, str]) -> str:
    tokens = dict(pal)
    tokens["accent-rgb"] = ", ".join(str(round(c * 255)) for c in rgb(pal["accent"]))
    template = (REPO / QSS_TEMPLATE).read_text()

    def substitute(match: re.Match[str]) -> str:
        key = match.group(1)
        if key not in tokens:
            raise SystemExit(f"{QSS_TEMPLATE}: unknown palette token {key!r}")
        return tokens[key]

    return re.sub(r"\{\{([a-z-]+)\}\}", substitute, template)


def kdeglobals_drift(pal: dict[str, str]) -> list[str]:
    """kdeglobals is hand-maintained; only its AccentColor must track the palette."""
    path = REPO / KDEGLOBALS
    if not path.exists():
        return []
    expected = kcfg(pal["accent"])
    for line in path.read_text().splitlines():
        key, sep, value = line.partition("=")
        if sep and key.strip() in {"AccentColor", "LastUsedCustomAccentColor"}:
            if value.strip() != expected:
                return [f"{KDEGLOBALS}: {key.strip()}={value.strip()} should be {expected}"]
    return []


# --- driver ----------------------------------------------------------------


def build(pal: dict[str, str]) -> dict[str, str]:
    scheme = colours_scheme(pal)
    return {
        SCHEME_OUT: scheme,
        GTK3_OUT: gtk_css(pal, 3),
        GTK4_OUT: gtk_css(pal, 4),
        f"{THEME_DIR}/colors": scheme,
        f"{THEME_DIR}/plasmarc": THEME_PLASMARC,
        f"{THEME_DIR}/metadata.json": theme_metadata(),
        QSS_OUT: render_qss(pal),
    }


def report(pal: dict[str, str]) -> str:
    checks = [
        ("body: text on deep surface", pal["text"], pal["surface-deep"], 4.5),
        ("body: text on base surface", pal["text"], pal["surface-base"], 4.5),
        ("body: text on panel", pal["text"], pal["panel"], 4.5),
        ("body: muted on panel", pal["muted"], pal["panel"], 4.5),
        ("body: muted dim on panel", pal["muted-dim"], pal["panel"], 4.5),
        ("accent ink on accent", pal["accent-ink"], pal["accent"], 4.5),
        ("accent on panel", pal["accent"], pal["panel"], 3.0),
        ("border strong on panel", pal["line-strong"], pal["panel"], 3.0),
        ("hairline line on panel", pal["line"], pal["panel"], 3.0),
        ("disabled on panel", pal["disabled"], pal["panel"], 3.0),
    ]
    rows = ["pair                                 ratio   need  verdict"]
    for name, fg, bg, need in checks:
        ratio = contrast(fg, bg)
        rows.append(f"{name:<36} {ratio:5.2f}   {need:4.1f}  {'ok' if ratio >= need else 'FAIL'}")
    return "\n".join(rows)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="exit 1 if generated files are stale")
    parser.add_argument("--report", action="store_true", help="print the palette contrast table")
    parser.add_argument("--out", type=Path, help="output root (default: repo root)")
    args = parser.parse_args()

    pal = derive(parse_palette(PALETTE_PATH))
    if args.report:
        print(report(pal))
        return 0

    root = args.out or REPO
    stale: list[str] = []
    for rel, content in build(pal).items():
        target = root / rel
        current = target.read_text() if target.exists() else None
        if current == content:
            continue
        if args.check:
            stale.append(rel)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
            print(f"wrote {rel}")

    drift = kdeglobals_drift(pal)
    if drift:
        if args.check:
            stale.extend(drift)
        else:
            for message in drift:
                print(f"warning: {message}", file=sys.stderr)

    if args.check and stale:
        print("stale generated files:", file=sys.stderr)
        for rel in stale:
            print(f"  {rel}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
