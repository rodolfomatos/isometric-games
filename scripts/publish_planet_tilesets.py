#!/usr/bin/env python3
"""Publish a tileset per planet, and describe it from the sheet it comes from.

The image in the tileset is named by its file name alone: flame_tiled resolves a
tileset's image under `assets/images/`, and a path that already starts with
`assets/images/` asks for `assets/images/assets/images/castle.png`, which is
what the first version of this wrote and what the room tests caught.

Four of the five planets had no tileset the game could load: the world names a
theme for every room, `generate_rooms.dart` asked for `<theme>.tsx`, and only
`castle.tsx` existed, so every room in every planet drew the castle. The art was
not missing. `assets/sprites/tiles/<theme>.png` is a 1024x512 sheet for each of
them, and what was missing was the description of that sheet and a copy the game
can load.

The tile count and the column count are measured from the PNG rather than
written down here, so a sheet that changes size cannot leave a tileset lying
about it. Run with `--check` to verify what is published without writing.
"""

import argparse
import struct
import sys
from pathlib import Path

from PIL import Image

from tileset_geometry import apply_diamond_mask

ROOT = Path(__file__).parent.parent
GAME = ROOT / "games" / "headoverheels"
# The worlds' themes, and the sheet each one's art lives in.
#
# Castle used to point at `assets/images/castle.png` — the published file — with a
# comment saying an older generator had written it straight there. Which means
# there was nothing to copy, nothing to check, and the sheet the game draws was
# whatever that generator left behind: 726 opaque pixels out of 524,288. The
# castle is where a party starts, so the first room of the game had no floor, and
# nothing said so. The art was in the repository the whole time, one directory
# away, written by `generate_castle_tileset.py`.
THEMES = {
    "castle": GAME / "assets" / "sprites" / "tiles" / "castle" / "castle_masters.png",
    "egyptus": GAME / "assets" / "sprites" / "tiles" / "egyptus.png",
    "penitentiary": GAME / "assets" / "sprites" / "tiles" / "penitentiary.png",
    "safari": GAME / "assets" / "sprites" / "tiles" / "safari.png",
    "bookworld": GAME / "assets" / "sprites" / "tiles" / "bookworld.png",
}
TILE_W, TILE_H = 64, 32
# A sheet is mostly unused: the generators draw the families they need and leave
# the rest of the 256 cells empty, so the castle sits at 6% while every tile its
# rooms actually reference is a full diamond. This floor is therefore only here to
# catch a sheet that never got its art at all — the castle was 0.1% for years and
# the check called it published. Whether the tiles a room *uses* are drawn is a
# sharper question, and it is asked per tile in the Dart test, where the room
# data lives.
MIN_OPAQUE = 0.02
COLUMNS = 16
TILESET_ROOT = GAME / "assets" / "levels" / "tilesets"

TSX = """<?xml version='1.0' encoding='utf-8'?>
<tileset version="1.10" tiledversion="1.10.0" name="{theme}" tilewidth="{tile_w}" tileheight="{tile_h}" tilecount="{count}" columns="{columns}">
 <grid orientation="isometric" width="{tile_w}" height="{tile_h}" />
 <image source="{image_source}" width="{width}" height="{height}" />
</tileset>
"""


def already_masked(image: Image.Image) -> bool:
    """Whether a sheet is already cut into diamonds.

    A masked tile is transparent at its four corners and opaque at its middle, so
    the first tile's corners answer the question without counting pixels.
    """
    alpha = image.convert("RGBA").getchannel("A")
    corners = ((0, 0), (TILE_W - 1, 0), (0, TILE_H - 1), (TILE_W - 1, TILE_H - 1))
    return all(alpha.getpixel(corner) == 0 for corner in corners)


def opaque_fraction(image: Image.Image) -> float:
    """How much of a sheet carries a pixel at all."""
    alpha = image.convert("RGBA").getchannel("A")
    opaque = sum(1 for value in alpha.getdata() if value > 0)
    return opaque / float(alpha.size[0] * alpha.size[1])


def png_size(path: Path) -> tuple:
    """The size of a PNG, from its own header."""
    with open(path, "rb") as handle:
        head = handle.read(33)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} is not a PNG")
    return struct.unpack(">II", head[16:24])


def build(theme: str, source: Path, check: bool) -> bool:
    """Publish one planet's tileset. Returns whether it is already right."""
    if not source.exists():
        print(f"{theme}: no art at {source}", file=sys.stderr)
        return False

    width, height = png_size(source)
    rows = height // TILE_H
    columns = width // TILE_W
    count = rows * columns

    published = TILESET_ROOT / f"{theme}.png"
    tileset = TILESET_ROOT / f"{theme}.tsx"
    wanted_image = f"assets/levels/tilesets/{theme}.png"
    # Next to the .tsx, because that is how flame_tiled resolves an image
    # reference: the file that names it.
    #
    # The sheet used to be published to `assets/images/{theme}.png`, which the
    # pubspec does not ship, so it never reached the build -- and the source was
    # `{theme}.png` all along, correctly pointing beside the .tsx at a file that
    # was not there. Every room in every planet drew untextured tiles: the floor
    # and the 1310 wall tiles that decide collision, together. This script
    # reported every planet as published, because it compared the .tsx against
    # what it wanted to write and computed `wanted_image` from the start and
    # compared that with nothing.
    image_source = f"{theme}.png"
    wanted_tileset = TSX.format(
        theme=theme,
        tile_w=TILE_W,
        tile_h=TILE_H,
        count=count,
        columns=columns,
        image_source=image_source,
        width=width,
        height=height,
    ).strip()

    problems = []
    if not published.exists():
        problems.append(f"missing {published.relative_to(GAME)}")
    elif png_size(published) != (width, height):
        problems.append(
            f"{published.name} is {png_size(published)}, the art is {(width, height)}"
        )
    elif opaque_fraction(Image.open(published)) < MIN_OPAQUE:
        # A sheet of mostly transparent pixels is not a tileset, it is a room
        # with no floor in it. The castle sat at 0.1% and the check called it
        # published, because the check compared dimensions and never looked.
        problems.append(
            f"{published.name} is "
            f"{opaque_fraction(Image.open(published)):.1%} opaque, which is a "
            f"planet with no floor rather than a tileset"
        )
    if not tileset.exists():
        problems.append(f"missing {tileset.relative_to(GAME)}")
    elif tileset.read_text().strip() != wanted_tileset:
        problems.append(f"{tileset.name} does not describe {source.name}")
    elif not (TILESET_ROOT / image_source.format(theme=theme)).resolve().exists():
        # The last check, and the one that was missing: not "does the sheet exist"
        # -- it does -- but "does the path the game is told to load resolve".
        problems.append(
            f"{tileset.name} names an image at "
            f"{image_source.format(theme=theme)}, which does not exist"
        )

    if not problems:
        print(f"{theme}: {count} tiles in {columns} columns, published")
        return True

    if check:
        for problem in problems:
            print(f"{theme}: {problem}", file=sys.stderr)
        return False

    # The sheets are drawn as squares and the game draws them as diamonds, so the
    # mask is applied on the way out. Applying it to an already-masked sheet
    # changes nothing, which is what makes this safe to run twice.
    TILESET_ROOT.mkdir(parents=True, exist_ok=True)
    if source != published:
        image = Image.open(source).convert("RGBA")
        # Every sheet is written already masked, by `save_masked` in the
        # generators. Masking one again is not the no-op the old comment claimed:
        # on the castle it took the art from 33,760 opaque pixels to 726.
        if not already_masked(image):
            apply_diamond_mask(image)
        image.save(published, optimize=True)
    tileset.write_text(wanted_tileset + "\n")
    print(f"{theme}: published {count} tiles")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero when a planet's tileset is not what this writes",
    )
    arguments = parser.parse_args()

    ok = True
    for theme, source in THEMES.items():
        ok = build(theme, source, arguments.check) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
