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