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

## The root cause, and it is not a rendering bug

The README says the entities "draw the sprites the manifest holds rather than the
coloured rectangles they stood in for, so what a player sees is art now". The
manifest agrees. `assets/sprites/manifest.yaml` has 65 entries including
`entity.door.closed -> entities/door/door_master.png` and
`entity.conveyor.belt -> entities/conveyor/conveyor_master.png`. The files exist.
The registry loads them. `showManifestSprite` builds a `SpriteComponent` from them.

And `door_master.png` is **a flat dark brown rectangle**. 1021 bytes. So is
`conveyor_master.png`, at 623.

Nothing is broken. Every link in the chain works. The sprite files themselves were
never drawn -- the AI pipeline is candidate-only and **no art has ever been
accepted**, so what is in `assets/sprites/entities/` are the placeholder rectangles
given a `.png` extension and a manifest entry.

This is why the film and the documentation disagree without either being wrong in
its own terms: the README describes the mechanism, and the mechanism works. It just
carries nothing.

Every gate is green because every gate asks *"is the file present and does it
decode?"* and never *"is it art?"*. That is the seventh time this repository has
produced a check that cannot fail, and it is the most expensive one, because it is
invisible from the terminal: `ls` shows 65 sprites and a manifest that resolves.

Two gates would have caught it, and neither exists:

- an art gate that measures information content -- a flat fill has almost no
  distinct colours and no edges, so "distinct colours >= 4 and a non-trivial
  bounding box of non-background pixels" rejects a placeholder without needing to
  know what a door should look like;
- a human-approved contact sheet, checked in, which is what section 21 of
  `docs/REIMAGINING.md` already asks for and which nothing implements.

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

## Art direction, from reference screenshots the operator supplied

Ten screenshots of the Spectrum original and the modern remake, kept outside the
repository. The constraint stands and is unaffected by having looked at them: the
1987 assets do not enter this project as art, as controls, as a LoRA, or as an
img2img target. Reference is how you know what to build; it is not a source of
pixels.

They change the diagnosis. Three things, in order of how much they matter.

### The walls are the art, and we draw none

Both versions spend their visual identity on the walls. The Spectrum room is a
plain grey diamond floor with **decorated walls** -- chevrons, brick, red
diamonds, ornamental borders, one wall face per pattern. The remake keeps the same
structure with wooden door panels, blue-and-gold columns and framed pictures.

Ours draws no walls at all. And this is not missing art: `castle_start.tmx` has
`Floor` and `Walls` layers, and `RoomComponent.isBlocked` reads the `Walls` layer
for collision. The walls are in the data, they decide where the party cannot go,
and they are invisible. That is the single biggest gap, and it is not an art
problem -- it is a rendering problem.

### Props are small sprites standing on the diamond, not bars

In both versions every prop is a small isometric sprite sitting inside its tile:
knights in helmets, treasure chests, frogs, monsters. Sizes are tile-scale.

Ours are axis-aligned rectangles in flat pixel space, and the conveyor is
`[1024.0, 32.0]` -- the full room width -- drawn as a straight bar across the
screen. In the originals a conveyor is a belt segment repeated along the floor.
So the conveyor is not just ugly, it is the wrong shape for its own size.

### The plain floor is period-correct, and that one is fine

The Spectrum floor *is* a plain grid. The remake textures it in dark brick. Ours is
a plain grid, which means it matches the 1987 original and not the remake. That is
a legitimate choice -- but it is currently a choice nobody made, so it should be
written down rather than inherited from a default.

## What would gate this

A render assertion per entity kind -- a door draws the door asset and not a flat
fill -- is the only thing that would have caught this. A contact sheet a human
looks at, checked into the repository, catches the rest. A threshold on "pixels
changed" cannot do this job and should stop being asked to: the party idles, so
the picture always changes.
