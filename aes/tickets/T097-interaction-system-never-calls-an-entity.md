---
id: T097
status: closed
severity: critical
found_by: following T095's real question through the interaction path
---

# T097 — CLOSED: three breaks in a chain, and a door that was a stub

## The finding

`InteractionSystem.update()` is the only thing in the game that hands a character
to an entity:

```dart
// systems/interaction_system.dart:39
for (final character in _characters) {
  for (final entity in _entities) {
    _checkInteraction(character, entity);
  }
}
```

and `_checkInteraction` does the AABB test and, on the rising edge, calls
`entity.onEnter(character)` (line 58). That is the whole mechanism.

**`_entities` is empty.** `registerEntity` exists (line 26) and is called from
nowhere in `lib/`:

```
$ grep -rn "registerCharacter\|registerEntity" --include="*.dart" games/headoverheels/lib
game.dart:296:    _interactionSystem.registerCharacter(head);
game.dart:301:    _interactionSystem.registerCharacter(heels);
```

Two characters, zero entities, for the entire game.

So `onEnter` is never invoked on anything. Not on a door, not on a switch, not on
a spring, not on a guardian, not on a monster.

## Why it looks like a door problem, and is not

This is what T095 was circling for sixteen browser walks. The measurement that
settles it, from a widget test against the real game:

- the party was placed one tile from `castle_start`'s east door, at (14,8);
- the door is at (15,8);
- the party was moved onto the door tile and held there for 60 engine steps;
- **the room did not change.**

Nothing in the room is interactive. Doors are the visible symptom because they
are the one thing a player must touch to finish a room.

## Part 1 is done: entities are registered (this commit)

`RoomComponent` takes an optional `interactionSystem` and registers each entity it
spawns; `game.dart` passes its own in and unregisters the previous room's entities
before removing them. The unregistration is not tidiness -- the system keeps its
own list and does not follow the component tree, so an entity left behind keeps
being overlap-tested against the party for the rest of the game, from a room that
no longer exists.

`entity_interaction_test.dart` covers it with a conveyor, and it has a control
first: the party stands on bare floor and must not move. Without that control a
system that fired every entity everywhere would satisfy "the conveyor pushed the
party", and the test would be worth nothing.

Two things the test had to get right, both of which it got wrong first:

- **The tile is read from the room**, not hard-coded, so a map edit cannot leave
  it testing a tile that is no longer a conveyor.
- **Positions are in pixels.** Entities are placed by the same `gridToScreen` the
  doors use -- the conveyor on tile (0,6) sits at (-192,96) -- and
  `CharacterComponent._syncFromState` does `position = gridToScreen(state.position)`,
  so the party's component position is in the same space. The first run set it to
  `(0,6)` in *tile* units and reported the conveyor broken with the two 200 pixels
  apart in different coordinate spaces. A red test is not automatically a finding.

Doors are unaffected by this commit and still do nothing. They are `onInteract`,
and there is still no action path.

## The design says two mechanisms, and the game implements neither

The base class documents them, and this is the part that makes the diagnosis
complete rather than merely suspicious:

```dart
// puzzle_entity.dart:147
/// Called when character interacts (presses action key while overlapping).
void onInteract(CharacterComponent character);

/// Called when character enters trigger zone.
void onEnter(CharacterComponent character) {}
```

So the intended design is two callbacks, not one: **walk into it** fires `onEnter`,
and **press the action key while overlapping** fires `onInteract`. Doors implement
`onInteract`, so a door is meant to be opened on a key press, standing next to it.

Both are dead, for separate reasons:

1. `onEnter` is dead because `registerEntity` is never called (above).
2. `onInteract` is dead because there is no action path at all. `game_screen.dart`
   routes every action key through `_act`, and `_act` handles exactly four:

   ```dart
   case 'jump': case 'carry': case 'fire': case 'swop':
   ```

   There is no `interact` in `_actions` and no case for one. `actionForKey` can
   return the name of an action, and nothing can act on an entity with it.

## Why the one-line fix would have been wrong

It is tempting to collapse the two callbacks -- make `PuzzleEntity.onEnter`
delegate to `onInteract` -- and that would make every handler reachable in one
place without touching the twelve files. It is also wrong: it makes **doors open
by walking into them**, which contradicts the documented design and changes the
game rather than repairing it. Walking into a door and choosing to open it are
different acts, and only one of them is what this game means.

So the fix has two independent parts, and the first one is not optional:

1. `RoomComponent._spawnEntities` must register each entity it spawns, and the
   room teardown in `game.dart:_loadRoom` must unregister it. Without the second
   half, `_entities` grows a room at a time and entities from rooms the party left
   keep firing.
2. An `interact` action: a key in `InputSystem._actions`, a case in `_act`, and a
   route from there to `InteractionSystem`, which then calls `onInteract` on
   whatever the character currently overlaps. This one crosses the widget/game
   boundary -- `game_screen` holds the input and the `FlameGame` owns the
   `InteractionSystem` -- so it needs a decision about how the two reach each
   other, and that decision is not made here.

## The second half of it, which is why the obvious fix does not work

`_DoorEntity` (`entity_factory.dart:111`) implements **`onInteract`** -- that is
where the transition lives -- and does **not** override `onEnter`. So the obvious
one-line fix, delegating `onEnter` to `onInteract`, changes nothing at all: the
system never calls `onEnter` either, because `_entities` is empty.

I made that change, ran the traversal test, and it still failed. It is reverted.
Shipping it with a comment saying it fixed doors would have been the worst
outcome available: a fix that reads as a fix and changes nothing.

The shape of it is worth naming. **Twelve entity files implement `onInteract`;
five implement `onEnter`.** `PuzzleEntity.onEnter` is an empty body
(`puzzle_entity.dart:151`), so everything that spells its handler `onInteract` --
doors, chests, keys, dropped items, fish, the crown, the dispensary, the hush
puppy, the bag -- inherits a no-op. Only the entities that happened to use the
system's spelling have ever done anything.

`onInteract` is called from `tests/gameplay_compiles_test.dart` and nowhere else.
The tests pass because they invoke the handler directly.

## Also dead, found on the way

`RoomGraph.getExit(roomId, direction)` (`room_graph.dart:192`) resolves an exit by
direction, which would be the natural way for a door to work if a party walks into
the wall. Nothing calls it outside the class. So there are two plausible door
mechanisms in this codebase and neither is connected to anything.

## What fixing it involves, and the risk

Two parts, and the first is not optional:

1. `RoomComponent._spawnEntities` adds each entity to the room and nothing else.
   Something has to call `registerEntity` for each one. The timing is the risk:
   `_spawnEntities` runs in `onLoad`, and `game.dart` creates the room and then
   `await world.add(room)`, so whether `room.entities` is populated at the call
   site depends on how far the async `onLoad` has got.
2. Decide the spelling. Renaming `onInteract` to `onEnter` across twelve files
   touches every handler and every test that calls it directly. Delegating
   `onEnter => onInteract` on `PuzzleEntity` once, in the base class, would make
   every existing handler reachable without touching the twelve -- and would give
   the other direction of the bug, `onExit`, the same treatment for free.

Part 2 in the base class is the smaller change and it is the one that makes the
seven currently-dead entity types work. It should not be done without part 1, or
it changes nothing in the same way my reverted fix did.

## What is not claimed

No player-facing claim. This has not been watched in a browser, and the fps there
is four to six, so a door opening on screen is not something I have seen. What is
measured: the party can stand on a door tile for sixty engine steps of the real
game and the room does not change, and no code path registers an entity with the
system that would change it.

## Closed, and the real cause was under all of it

Wiring the action path in made the key reach an entity -- and the room still did
not change. The reason is the plainest thing in this whole ticket, and it was
underneath everything above it:

```dart
void _triggerTransition(CharacterComponent character) {
  // Room transition handled by game system
  // This would emit an event to the game manager
}
```

**`_DoorEntity._triggerTransition` was an empty method.** Two comments where the
code should be. So a door could be walked into, stood beside and opened with the
action key, and there was nothing between the key check and the room changing.

Everything else about a door was real. The map declares 42 of them with positions,
sizes and exits. `HeadOverHeelsGame.transitionTo` was written, and
`room_transition_test.dart` tests it thoroughly. The door entity simply was never
connected to any of it.

```dart
unawaited(game.transitionTo(targetRoom, targetEntrance));
```

Fire and forget on purpose: `transitionTo` is async and this is a synchronous
callback in the middle of the interaction system's overlap loop, so awaiting here
would hold the loop open across a room change.

## Three breaks in one chain

Worth stating plainly, because the shape is the lesson. Any one of these and the
door is inert; all three were present at once, and each one hid the next:

1. **`registerEntity` was never called**, so `_entities` was empty and `onEnter`
   never fired. Fixed in `7cc09de`.
2. **`onInteract` had no caller and no key.** There was no `interact` in
   `InputSystem._actions`, no case in `_act`, and the widget holding the keyboard
   had no route to the `InteractionSystem` the game owned. Now: `keyE`/`Enter`
   bound to `interact`, `InteractionSystem.onActionPressed()` acting on whatever
   overlaps, and one `interactionSystemProvider` so the game and the widget are
   looking at the same instance rather than each holding their own.
3. **`_triggerTransition` was empty.** The handler ran and did nothing.

Fixing one link changes nothing, which is what the reverted `onEnter` delegation
showed and what the failed traversal test showed twice. The only reason the chain
was walked to the end is that each step had a measurement that could have been
wrong: floor does not move the party, the action key reached an entity and the
room stayed put. A green test at step two would have been a green test of a stub.

## What is now covered

- `entity_interaction_test.dart` -- `onEnter` fires. Conveyor, with a control that
  bare floor moves nothing.
- `door_interaction_test.dart` -- `onInteract` fires and the room changes. The
  party stands beside the door and the room must *not* change first, so a door
  that opened on approach could not pass it.

Not covered, and not claimed: chests, keys, dropped items, fish, the crown, the
dispensary, the bag and the hush puppy are `onInteract` entities too, so they are
now reachable for the first time -- and some of them have never had a body behind
their handler. They are worth one ticket each, and they should be opened by
playing rather than by reasoning about it.
