#!/usr/bin/env python3
"""Builds the contact sheet a human approves art from.

T098: 24 of the 65 sprites under `assets/sprites/` are flat fills. The content
gate knows that and says so in a list, and a list does not let anyone *see* it.
You cannot eyeball "24 files are placeholders" and you cannot eyeball whether a
new sprite is good.

So this lays every sprite out on one sheet, on a checkerboard so transparency is
visible, scaled up with nearest-neighbour so a 1-pixel mistake is not invisible at
1:1. Composited from the files themselves rather than filmed in the browser: a
sheet has to be reproducible, and a browser here renders at four to six frames a
second.

The sheet has no labels because this script has no font. The grid order is
manifest order, and `docs/ART_REVIEW.md` carries the numbered list in that same
order with each file's verdict from the content gate, so the two are read
together.

    python3 scripts/art_contact_sheet.py
"""

from __future__ import annotations

import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import browser_pixels as bp  # noqa: E402
import validate_art_content as art  # noqa: E402

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SPRITES = art.SPRITES
MANIFEST = SPRITES / "manifest.yaml"
SHEET = REPO_ROOT / "docs" / "art-contact-sheet.png"
REVIEW = REPO_ROOT / "docs" / "ART_REVIEW.md"

TILE = 96          # each cell, in sheet pixels
PAD = 8
COLUMNS = 8
SCALE = 2          # nearest-neighbour, because smoothing hides the mistake

CHECKER_A = (58, 58, 64)
CHECKER_B = (44, 44, 50)
CELL_BG = (28, 28, 32)


def manifest_files() -> list[str]:
    """Manifest order, which is the order the sheet uses.

    The manifest is the thing the game actually loads, so the sheet shows what the
    game will draw rather than whatever happens to be in the directory.
    """
    if not MANIFEST.exists():
        return []
    text = MANIFEST.read_text(encoding="utf-8")
    return [m.group(1).strip() for m in re.finditer(r"^\s*file:\s*(\S+)", text,
                                                    re.MULTILINE)]


def write_png(path: pathlib.Path, width: int, height: int,
              pixels: bytearray) -> None:
    import struct
    import zlib

    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)
        raw.extend(pixels[y * stride:(y + 1) * stride])

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw)))
        + chunk(b"IEND", b""))


def blit(sheet: bytearray, sheet_w: int, cell_x: int, cell_y: int,
         sprite: tuple[int, int, int, bytes], span: int) -> None:
    """Nearest-neighbour upscale into a cell, centred, over a checkerboard."""
    width, height, channels, pixels = sprite
    # Scale to fit, never past the cell. A fixed multiplier overflowed any sprite
    # bigger than 40 pixels, the sampler clamped at the edge, and the clamp drew a
    # diagonal X across the prop -- an artefact of this sheet, sitting in the exact
    # place a reviewer would read as a defect in the art. A contact sheet that
    # misrepresents the art is worse than no contact sheet.
    scale = max(1, min(SCALE, span // max(width, 1), span // max(height, 1)))
    draw_w, draw_h = width * scale, height * scale
    offset_x, offset_y = (span - draw_w) // 2, (span - draw_h) // 2
    for y in range(span):
        for x in range(span):
            px = cell_x + PAD + x
            py = cell_y + PAD + y
            if px >= sheet_w:
                continue
            checker = CHECKER_A if ((x // 8) + (y // 8)) % 2 == 0 else CHECKER_B
            offset = (py * sheet_w + px) * 4
            # Sample the sprite at the centre of this output pixel's source.
            if x < offset_x or y < offset_y or x >= offset_x + draw_w \
                    or y >= offset_y + draw_h:
                r, g, b = checker
            else:
                sx = min(width - 1, (x - offset_x) // scale)
                sy = min(height - 1, (y - offset_y) // scale)
                i = (sy * width + sx) * channels
                if channels >= 4 and pixels[i + 3] < 16:
                    r, g, b = checker
                else:
                    r, g, b = pixels[i], pixels[i + 1], pixels[i + 2]
            sheet[offset:offset + 4] = bytes((r, g, b, 255))


def main() -> int:
    files = manifest_files() or [
        str(p.relative_to(SPRITES)) for p in sorted(SPRITES.rglob("*.png"))
    ]
    seen: set[str] = set()
    entries: list[tuple[str, str, int]] = []
    for relative in files:
        if relative in seen:
            continue
        seen.add(relative)
        path = SPRITES / relative
        if not path.exists():
            continue
        row = art.analyse(path)
        verdict = ("placeholder" if row["colours"] < art.MIN_OPAQUE_COLOURS
                   else "drawn")
        entries.append((relative, verdict, row["colours"]))

    if not entries:
        print("no sprites found", file=sys.stderr)
        return 2

    span = TILE - PAD * 2
    cell = TILE + PAD
    rows = (len(entries) + COLUMNS - 1) // COLUMNS
    sheet_w = COLUMNS * cell + PAD
    sheet_h = rows * cell + PAD
    sheet = bytearray()
    for y in range(sheet_h):
        for x in range(sheet_w):
            colour = CELL_BG if (x < PAD or y < PAD or x >= sheet_w - PAD
                                 or y >= sheet_h - PAD) else CHECKER_B
            sheet.extend(bytes((*colour, 255)))

    for index, (relative, _, _) in enumerate(entries):
        column, row = index % COLUMNS, index // COLUMNS
        try:
            sprite = bp.decode(SPRITES / relative)
        except Exception as error:  # noqa: BLE001
            print(f"  -- {relative}: cannot decode ({error})")
            continue
        blit(sheet, sheet_w, PAD + column * cell, PAD + row * cell, sprite, span)

    write_png(SHEET, sheet_w, sheet_h, sheet)

    placeholders = [e for e in entries if e[1] == "placeholder"]
    lines = [
        "# Art review",
        "",
        "Generated by `scripts/art_contact_sheet.py`. Read it together with",
        f"[`art-contact-sheet.png`](art-contact-sheet.png): the sheet shows the",
        "sprites in the order below, one per cell, left to right.",
        "",
        f"- **{len(entries)}** sprites in the manifest.",
        f"- **{len(placeholders)}** are flat fills and show as plain rectangles.",
        f"- **{len(entries) - len(placeholders)}** carry drawn art.",
        "",
        "A placeholder here is debt, not approval -- see",
        "`scripts/art_content_baseline.txt`. The gate rejects a *new* flat fill; it",
        "does not decide whether a drawn sprite is any good. That is this page's",
        "job, and it is a person's.",
        "",
        "## The sheet",
        "",
        "| # | sprite | verdict | opaque colours |",
        "|---|--------|---------|----------------|",
    ]
    for index, (relative, verdict, colours) in enumerate(entries, 1):
        lines.append(f"| {index} | `{relative}` | {verdict} | {colours} |")

    lines += [
        "",
        "## What is not decided here",
        "",
        "Colour count cannot tell a good sprite from a bad one, and it cannot tell",
        "a *simple* prop from a placeholder -- a plain wooden barrel might have three",
        "colours and be perfectly real art. So this page and the gate are two halves",
        "of one question, and neither answers it alone.",
        "",
    ]
    REVIEW.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"wrote {SHEET.relative_to(REPO_ROOT)} ({sheet_w}x{sheet_h}, "
          f"{len(entries)} cells, {COLUMNS} per row)")
    print(f"wrote {REVIEW.relative_to(REPO_ROOT)}")
    print(f"  {len(placeholders)} placeholder, {len(entries) - len(placeholders)} "
          f"drawn")
    return 0


if __name__ == "__main__":
    sys.exit(main())