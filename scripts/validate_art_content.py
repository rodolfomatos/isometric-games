#!/usr/bin/env python3
"""Rejects placeholder art that only *looks* like a sprite file.

T098: `assets/sprites/entities/door/door_master.png` is a flat brown rectangle,
1021 bytes. So is every prop, and thirteen of the fourteen entities. The manifest
resolves them, the registry loads them, `showManifestSprite` builds a component from
them, and the player sees a rectangle -- while `ls` shows sixty-five sprites and
every gate in this repository is green.

Nothing asked whether the file contained art. `validate_sprites.py` checks that it
exists and decodes; the AI pipeline is candidate-only so nothing was ever accepted.
A placeholder with a `.png` extension and a manifest entry passes every check this
project had.

So this asks a different question: does the file carry any information?

The threshold is measured, not guessed. Across the 68 PNGs under
`assets/sprites/`, the colour counts separate into two groups with nothing between
them:

    entities/*, props/*        2-3 distinct colours     <- flat fills
    characters/*               5-9 distinct colours     <- drawn
    tiles/*                    8-18 distinct colours    <- drawn

Four is the floor of the real group. The caveat is in the code and matters: a
genuinely simple prop -- a plain wooden barrel -- could have three colours and be
real art. This gate is therefore scoped to what it can decide, which is "this is a
flat fill", and the human contact sheet is what decides whether a sprite is *good*.
Both are needed; neither replaces the other.

    python3 scripts/validate_art_content.py [--verbose]
"""

from __future__ import annotations

import argparse
import collections
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import browser_pixels as bp  # noqa: E402

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SPRITES = REPO_ROOT / "games" / "headoverheels" / "assets" / "sprites"
BASELINE = pathlib.Path(__file__).resolve().parent / "art_content_baseline.txt"

# The floor of the real-art group, measured above. A flat fill has one or two.
MIN_OPAQUE_COLOURS = 4

# A sprite whose opaque area is this small is a dot, whatever its colour count.
MIN_OPAQUE_FRACTION = 0.01


PLACEHOLDER = "placeholder"
DRAWN = "drawn"

TILESETS = REPO_ROOT / "games" / "headoverheels" / "assets" / "levels" / "tilesets"
ROOMS = REPO_ROOT / "games" / "headoverheels" / "assets" / "levels" / "rooms"

LAYER = re.compile(r'<layer[^>]*name="([^"]+)"[^>]*>(.*?)</layer>', re.S)
DATA = re.compile(r"<data[^>]*>(.*?)</data>", re.S)
IMAGE = re.compile(
    r'<image[^>]*source="([^"]+)"[^>]*width="(\d+)"[^>]*height="(\d+)"')
TILE_W, TILE_H = 64, 32


def room_gids() -> dict:
    """Which gids each theme's rooms actually name.

    Only these matter. A sheet has 256 cells and a room names a handful; judging
    the unused remainder is how a sheet passes a per-file check while everything
    it draws is flat. This is the sibling of the Dart test "every tile a room
    names is a tile the tileset has" -- the tile existing is the first half, and
    the tile carrying art is the half nothing was asking for.
    """
    used: dict = {}
    for tmx in sorted(ROOMS.rglob("*.tmx")):
        text = tmx.read_text(encoding="utf-8")
        reference = re.search(r"<tileset[^>]*>", text)
        source = re.search(r'source="([^"]+)"', reference.group(0)) if reference else None
        if not source:
            continue
        theme = pathlib.Path(source.group(1)).stem
        bucket = used.setdefault(theme, set())
        for layer in LAYER.finditer(text):
            data = DATA.search(layer.group(2))
            if not data:
                continue
            for value in re.findall(r"\d+", data.group(1)):
                gid = int(value)
                if gid:
                    bucket.add(gid)
    return used


def analyse_tileset(theme: str, gids: set) -> list:
    """Per-tile verdict for the gids a room names. Returns the placeholders."""
    tsx = TILESETS / f"{theme}.tsx"
    if not tsx.exists():
        return [{"theme": theme, "gid": 0, "reason": f"no {tsx.name}"}]
    image = IMAGE.search(tsx.read_text(encoding="utf-8"))
    if not image:
        return [{"theme": theme, "gid": 0,
                 "reason": f"{tsx.name} names no image"}]
    sheet = TILESETS / image.group(1)
    if not sheet.exists():
        return [{"theme": theme, "gid": 0,
                 "reason": f"{tsx.name} names {image.group(1)}, which is not "
                           f"there. A path that cannot resolve draws nothing "
                           f"and says nothing either."}]

    width, height, channels, pixels = bp.decode(sheet)
    columns = max(1, width // TILE_W)
    bad: list = []
    for gid in sorted(gids):
        index = gid - 1
        cx, cy = (index % columns) * TILE_W, (index // columns) * TILE_H
        colours = set()
        opaque = 0
        for y in range(cy, min(cy + TILE_H, height)):
            for x in range(cx, min(cx + TILE_W, width)):
                offset = (y * width + x) * channels
                if channels >= 4 and pixels[offset + 3] < 16:
                    continue
                opaque += 1
                colours.add((pixels[offset], pixels[offset + 1],
                             pixels[offset + 2]))
        fraction = opaque / float(TILE_W * TILE_H)
        thin = fraction < MIN_OPAQUE_FRACTION
        flat = len(colours) < MIN_OPAQUE_COLOURS
        if thin or flat:
            bad.append({
                "theme": theme, "gid": gid, "colours": len(colours),
                "opaque_fraction": fraction,
                "reason": f"{len(colours)} opaque colour"
                          f"{'' if len(colours) == 1 else 's'}, "
                          f"{fraction * 100:.0f}% of the tile opaque"
                          + (" -- a flat fill, not art" if flat
                             else " -- too empty to be a tile"),
            })
    return bad


def analyse(path: pathlib.Path) -> dict:
    """Distinct opaque colours and how much of the image is opaque."""
    width, height, channels, pixels = bp.decode(path)
    stride = width * channels

    colours: collections.Counter = collections.Counter()
    opaque = 0
    for i in range(0, len(pixels), channels):
        if channels >= 4 and pixels[i + 3] < 16:
            continue  # effectively transparent
        opaque += 1
        colours[(pixels[i], pixels[i + 1], pixels[i + 2])] += 1

    total = width * height
    return {
        "path": path,
        "size": (width, height),
        "channels": channels,
        "opaque": opaque,
        "opaque_fraction": opaque / total if total else 0.0,
        "colours": len(colours),
        "dominant_share": (colours.most_common(1)[0][1] / opaque
                           if opaque else 1.0),
    }


def known_placeholders() -> set[str]:
    """The debt, written down.

    A baseline rather than a failing gate, because this repository should not go
    red on a Tuesday for something that was already true on Monday. The rule is
    one-sided and deliberate: a file *may* stay a placeholder if it is already
    listed here, and nothing new may join the list by being committed. The file is
    debt, not approval, and adding to it needs a human to have looked at the art.
    """
    if not BASELINE.exists():
        return set()
    return {line.strip() for line in BASELINE.read_text().splitlines()
            if line.strip() and not line.startswith("#")}


TILESET_BASELINE = pathlib.Path(__file__).resolve().parent / "tileset_baseline.txt"


def known_tileset_debt() -> set[str]:
    """Themes already published as flat diamonds. Debt, not approval.

    One line per theme rather than per gid, because a theme's 256 cells are all
    the same shape of failure and a per-gid baseline would be a list nobody reads
    and nobody prunes.
    """
    if not TILESET_BASELINE.exists():
        return set()
    return {line.strip() for line in TILESET_BASELINE.read_text().splitlines()
            if line.strip() and not line.startswith("#")}


def check_tilesets() -> tuple[list[dict], list[dict], int]:
    used = room_gids()
    allowed = known_tileset_debt()
    failures: list[dict] = []
    grandfathered: list[dict] = []
    tiles = 0
    for theme, gids in sorted(used.items()):
        tiles += len(gids)
        for bad in analyse_tileset(theme, gids):
            if theme in allowed:
                bad["theme"] = theme
                grandfathered.append(bad)
            else:
                failures.append(bad)
    return failures, grandfathered, tiles


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)

    if not SPRITES.is_dir():
        print(f"[!!] no sprites at {SPRITES}", file=sys.stderr)
        return 2

    allowed = known_placeholders()
    failures: list[tuple[dict, str]] = []
    grandfathered: list[dict] = []
    rows: list[dict] = []

    for png in sorted(SPRITES.rglob("*.png")):
        try:
            row = analyse(png)
        except Exception as error:  # noqa: BLE001
            failures.append(({"path": png}, f"cannot decode: {error}"))
            continue
        rows.append(row)
        relative = str(png.relative_to(SPRITES))

        if row["opaque"] == 0:
            reason = "entirely transparent"
        elif row["opaque_fraction"] < MIN_OPAQUE_FRACTION:
            reason = (f"only {row['opaque_fraction'] * 100:.1f}% of the image is "
                      f"opaque")
        elif row["colours"] < MIN_OPAQUE_COLOURS:
            reason = (f"{row['colours']} distinct opaque colour"
                      f"{'' if row['colours'] == 1 else 's'}, "
                      f"{row['dominant_share'] * 100:.0f}% of them one colour -- "
                      f"a flat fill, not art")
        else:
            continue

        if relative in allowed:
            row["reason"] = reason
            grandfathered.append(row)
        else:
            failures.append((row, reason))

    if args.verbose:
        print(f"{'file':56} {'size':>10} {'colours':>8} {'opaque':>7}")
        for row in rows:
            print(f"{str(row['path'].relative_to(SPRITES)):56} "
                  f"{row['size'][0]:>4}x{row['size'][1]:<5} "
                  f"{row['colours']:>8} "
                  f"{row['opaque_fraction'] * 100:>6.1f}%")

    print(f"analysed {len(rows)} sprite(s); "
          f"{len(grandfathered)} known placeholder(s), "
          f"{len(failures)} undeclared")

    for row, reason in failures:
        print(f"[!!] {row['path'].relative_to(SPRITES)}: {reason}")
        print("     This file is new or changed and carries no art. Draw it, or "
              "accept it deliberately -- a placeholder that reaches the manifest "
              "by accident is T098.")

    if grandfathered:
        print()
        print(f"debt, unchanged and not approved ({len(grandfathered)}):")
        for row in grandfathered:
            print(f"  -- {row['path'].relative_to(SPRITES)}: {row['reason']}")

    tile_failures, tile_debt, tiles = check_tilesets()
    themes = len(room_gids())
    print(f"tiles named by rooms: {tiles} across {themes} theme(s); "
          f"{len(tile_debt)} known flat, {len(tile_failures)} undeclared")

    for bad in tile_failures:
        print(f"[!!] {bad['theme']}.png gid {bad['gid']}: {bad['reason']}")
        print("     A tile a room names, with no art in it. The whole sheet can "
              "pass a per-file check while every tile it draws is flat, which is "
              "what the castle was.")

    if tile_debt:
        print()
        counts: dict[str, int] = {}
        for bad in tile_debt:
            counts[bad["theme"]] = counts.get(bad["theme"], 0) + 1
        print(f"tileset debt, unchanged and not approved "
              f"({len(tile_debt)} of {tiles}):")
        for theme, count in sorted(counts.items()):
            print(f"  -- {theme}.png: {count} tile(s) are flat diamonds")

    return 1 if failures or tile_failures else 0


if __name__ == "__main__":
    sys.exit(main())