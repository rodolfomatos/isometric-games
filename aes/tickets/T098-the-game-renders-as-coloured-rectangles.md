---
id: T098
status: open
severity: major
found_by: filming the game for the first time
---

# T098 — the game renders as coloured rectangles, and nothing said so

`scripts/browser_film.js` drives the real game with real input and writes a frame
per step. It is the first thing here that *looked* at the game rather than counting
pixels or reading a component tree. Frame 0 of `build/film/door2.json`:

![the game as it renders](/opt/headoverheels/headoverheels/build/film/door2_000_start.png)

Every entity in the room is an axis-aligned coloured rectangle. Orange, blue,
yellow, cyan, red, dark red, brown, pink, grey. No sprite art on any of them, and
no art is missing from disk in a way the validators can see: they are being drawn
this way on purpose, or by default.

## Why every gate was green

`make verify-browser` counts changed pixels and fails under 200. This frame changes
by tens of thousands of pixels when anything at all happens, so it passes
comfortably. The gate asks "did the picture change", and the picture changes
constantly -- the party has an idle animation, and a settled room still moves
~6,700 pixels between frames. A gate that asks whether a picture changed cannot
tell a room full of scenery from a room full of working objects.

Nothing in the repository had ever asserted anything about how the game *looks*.
`validate_sprites.py` checks the assets that exist. There is no asset for these
entities, so there is nothing to fail.

## The second thing in the frame

The conveyor is a 1024-pixel horizontal bar laid across the upper third of the
screen, running off the left edge of the room. The floor is a proper isometric
diamond; the props are not isometric at all. They are axis-aligned rectangles in
the same coordinate space as the entities -- which is why the conveyor's size is
`[1024.0, 32.0]`, the full room width in flat pixels.

So the room reads as an isometric floor with a strip of unrelated rectangles laid
over it. Whether the props should be isometric artwork or flat billboards is a
decision nobody has written down; right now they are neither, and the conveyor
specifically spans the whole room in a straight line across the screen.

## What the film did prove

The one piece of good news, and it is worth having: in frame 2, after the party
walked south, the rectangle beside it went from **blue to green**. That is the
switch highlight, which fires from `onEnter` -- the callback that T097 part 1
reconnected. It works in a real browser, driven by a real joystick drag, and not
only inside a widget test.

Also visible: the HUD hints read `arrows / WASD move   space / Z jump   X / C
carry   V / F fire   tab / Q swop`. The `interact` key added in T097 part 2 is not
listed, so a player has no way to know it exists. That is a one-line fix and it
belongs with this ticket rather than being lost.

## What this does not claim

No claim about how the game is *meant* to look -- there is no reference in the
repository, and the 1987 originals are not available to this project as a
standard. The claim is narrower: the game currently draws untextured rectangles
for every entity, the props are not isometric while the floor is, the interact key
is undocumented in the HUD, and no gate in the repository would notice any of it.

## What would actually gate this

Not a pixel count. The honest options are a render assertion per entity kind --
that a door draws the door asset and not a flat fill -- or a contact sheet a human
looks at, checked in. A threshold on "pixels changed" cannot do this job and should
not be asked to.