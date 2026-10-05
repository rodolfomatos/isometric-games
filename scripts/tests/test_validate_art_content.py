"""Tests for the art-content gate.

The gate exists because `door_master.png` is a flat brown rectangle and every
check this repository had said the art was fine: the file exists, it decodes, the
manifest resolves it, `ls` shows sixty-five sprites. So the test that matters most
is the second one -- the gate has to be able to fail, on the real file, not only on
a fixture built to fail.
"""

from __future__ import annotations

import importlib.util
import pathlib
import struct

import pytest
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "validate_art_content", ROOT / "scripts" / "validate_art_content.py")
art = importlib.util.module_from_spec(spec)
sys.modules["validate_art_content"] = art
spec.loader.exec_module(art)

SPRITES = art.SPRITES


def write_png(path: pathlib.Path, pixels: list[tuple[int, int, int, int]],
              width: int, height: int) -> None:
    """A minimal RGBA PNG, so the test needs no image library."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter: none
        for x in range(width):
            raw.extend(pixels[y * width + x])

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw)))
           + chunk(b"IEND", b""))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def flat_fill(path: pathlib.Path) -> None:
    write_png(path, [(120, 60, 40, 255)] * 64, 8, 8)


def drawn_sprite(path: pathlib.Path) -> None:
    pixels = [(0, 0, 0, 0)] * 64
    for i in range(64):
        pixels[i] = (200 - i % 7 * 20, 40 + i % 5 * 30, 90, 255)
    write_png(path, pixels, 8, 8)


# --- the real corpus --------------------------------------------------------

def test_the_real_door_sprite_is_a_flat_fill():
    """The file this gate was written for, measured rather than asserted."""
    row = art.analyse(SPRITES / "entities" / "door" / "door_master.png")

    assert row["colours"] < art.MIN_OPAQUE_COLOURS, (
        "door_master.png now carries art -- remove it from "
        "scripts/art_content_baseline.txt and the debt shrinks")


def test_real_drawn_art_passes():
    """The other direction. A gate that rejects everything is as useless."""
    for relative in ["characters/head/frames/head_idle_front_01.png",
                     "tiles/castle/castle_masters.png"]:
        row = art.analyse(SPRITES / relative)
        assert row["colours"] >= art.MIN_OPAQUE_COLOURS, (
            f"{relative} has {row['colours']} opaque colours and would be "
            "rejected by the gate")


def test_every_placeholder_is_listed_in_the_baseline():
    """No undeclared placeholder may exist, which is the whole gate."""
    assert art.main([]) == 0


# --- the gate can fail ------------------------------------------------------

def test_a_new_flat_fill_fails_the_gate(tmp_path, monkeypatch):
    """Not a fixture built to fail: the same shape as the real door sprite."""
    sprites = tmp_path / "sprites"
    sprites.mkdir()
    flat_fill(sprites / "entities" / "new_thing.png")
    monkeypatch.setattr(art, "SPRITES", sprites)
    monkeypatch.setattr(art, "known_placeholders", lambda: set())

    assert art.main([]) == 1


def test_removing_a_file_from_the_baseline_makes_the_gate_fail(
        tmp_path, monkeypatch):
    """The baseline is debt, not a waiver.

    If a placeholder can be deleted from the list and the gate stays green, then
    the list is decoration. This is the test that keeps the mechanism honest.
    """
    sprites = tmp_path / "sprites"
    sprites.mkdir()
    flat_fill(sprites / "door.png")
    monkeypatch.setattr(art, "SPRITES", sprites)
    monkeypatch.setattr(art, "known_placeholders", lambda: set())

    assert art.main([]) == 1, "an undeclared flat fill must fail"


def test_a_drawn_sprite_passes_in_isolation(tmp_path, monkeypatch):
    sprites = tmp_path / "sprites"
    sprites.mkdir()
    drawn_sprite(sprites / "a_door.png")
    monkeypatch.setattr(art, "SPRITES", sprites)
    monkeypatch.setattr(art, "known_placeholders", lambda: set())

    assert art.main([]) == 0


def test_an_entirely_transparent_sprite_fails(tmp_path, monkeypatch):
    sprites = tmp_path / "sprites"
    sprites.mkdir()
    write_png(sprites / "empty.png", [(0, 0, 0, 0)] * 64, 8, 8)
    monkeypatch.setattr(art, "SPRITES", sprites)
    monkeypatch.setattr(art, "known_placeholders", lambda: set())

    assert art.main([]) == 1


def test_a_one_pixel_sprite_fails(tmp_path, monkeypatch):
    """Opaque enough to decode, too small to be anything."""
    pixels = [(0, 0, 0, 0)] * 100
    pixels[50] = (10, 20, 30, 255)
    sprites = tmp_path / "sprites"
    sprites.mkdir()
    write_png(sprites / "dot.png", pixels, 10, 10)
    monkeypatch.setattr(art, "SPRITES", sprites)
    monkeypatch.setattr(art, "known_placeholders", lambda: set())

    assert art.main([]) == 1


def test_the_baseline_file_exists_and_is_not_empty():
    """A gate that consults a missing baseline would allow everything."""
    assert art.BASELINE.exists()
    assert len(art.known_placeholders()) >= 20


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))


# --- per-tile tileset analysis ---------------------------------------------
#
# The gate written twenty minutes earlier walked `assets/sprites/**` and nothing
# else, and analysed a tileset as a whole sheet. castle_masters.png has seven
# distinct colours across 256 tiles and passed, while every tile a room names in
# it is a flat diamond. A sheet averages its art away. These are the tests that
# close that hole.

def test_the_wall_tiles_a_room_names_are_flat():
    """Measured on the real thing, not asserted about a fixture."""
    used = art.room_gids()
    assert "castle" in used, "no castle rooms found to analyse"

    bad = art.analyse_tileset("castle", used["castle"])
    assert bad, (
        "the castle's floor and wall tiles now carry art -- delete 'castle' "
        "from scripts/tileset_baseline.txt and the debt shrinks")

    gids = {entry["gid"] for entry in bad}
    assert 17 in gids and 18 in gids, (
        f"expected the wall tiles to be flat, got {gids}")


def test_every_theme_is_currently_flat_and_says_so():
    used = art.room_gids()
    assert len(used) == 5, f"expected five themes, found {sorted(used)}"

    for theme, gids in used.items():
        bad = art.analyse_tileset(theme, gids)
        assert bad, f"{theme} reports no flat tile among {len(gids)}"


def test_the_gate_fails_on_a_theme_that_is_not_in_the_baseline(monkeypatch):
    monkeypatch.setattr(art, "known_tileset_debt", lambda: set())
    failures, debt, tiles = art.check_tilesets()

    assert failures, "a flat castle tile must fail with an empty baseline"
    assert len(debt) == 0
    assert tiles > 0


def test_removing_a_theme_from_the_baseline_makes_it_fail(monkeypatch):
    """The baseline is debt, not a waiver -- the same property as the sprite one."""
    monkeypatch.setattr(art, "known_tileset_debt", lambda: {"egyptus"})
    failures, debt, _ = art.check_tilesets()

    assert failures, "a theme left out of the baseline must fail"
    themes = {entry["theme"] for entry in debt}
    assert themes == {"egyptus"}


def test_an_image_path_that_cannot_resolve_is_reported(tmp_path, monkeypatch):
    """The bug that shipped: the sheet was published where nothing loaded it."""
    tilesets = tmp_path / "tilesets"
    tilesets.mkdir()
    (tilesets / "broken.tsx").write_text(
        '<tileset><image source="nowhere.png" width="64" height="32"/></tileset>',
        encoding="utf-8")
    monkeypatch.setattr(art, "TILESETS", tilesets)

    bad = art.analyse_tileset("broken", {1})
    assert bad and "not" in bad[0]["reason"] and "there" in bad[0]["reason"]


def test_the_sprite_gate_does_not_cover_the_tilesets(tmp_path, monkeypatch):
    """The hole, stated as a test so it cannot be forgotten again.

    The published sheets live in assets/levels/tilesets/. If this ever passes with
    a placeholder sheet, the sprite-only walk has swallowed the tilesets -- or the
    baseline has grown to cover them.
    """
    sprite_only = tmp_path / "sprites"
    sprite_only.mkdir()
    monkeypatch.setattr(art, "SPRITES", sprite_only)

    assert art.main([]) == 0, (
        "with no sprites at all the sprite pass should still be happy -- which "
        "is exactly why it missed every tileset")

