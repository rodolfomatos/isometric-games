// An entity the party walks onto has to do something.
//
// `InteractionSystem.update()` is the only thing in the game that hands a
// character to an entity, and it iterates `_entities`. `registerEntity` existed
// and nothing in `lib/` called it, so that list was empty for the whole game and
// `onEnter` was never fired on anything. Doors were the visible symptom because a
// door is what a player must touch to finish a room; nothing in the room was
// interactive at all.
//
// This uses a conveyor, because its `onEnter` is observable: it pushes the
// character. A switch's `onEnter` only changes a highlight, which nothing here can
// read, so a test on it would pass whether or not the system works.
//
// The second test is the one that gives the first its meaning. An assertion that
// "the conveyor pushed the party" is worth nothing on its own -- a system that
// pushed everything everywhere would also satisfy it. So the party is placed on
// bare floor first, and nothing may move.

import 'package:flame/components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:headoverheels/core/isometric.dart';
import 'package:headoverheels/features/gameplay/entities/character_component.dart';
import 'package:vector_math/vector_math.dart' show Vector3;

import 'support/hoh_frame.dart';

/// Engine steps given to an overlap test. One overlap check per step, and the
/// first one is the rising edge, so this is generous rather than tuned.
const int steps = 8;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<({LoadedGame loaded, CharacterComponent character})> settle(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final loaded = await loadRealGame(tester);
    expect(loaded, isNotNull, reason: 'the game never finished loading');
    freeze(loaded!.game);

    final characters = loaded.party;
    expect(
      characters,
      isNotEmpty,
      reason: 'the room has no party in it, so nothing can overlap anything',
    );
    return (loaded: loaded, character: characters.first);
  }

  /// Places the character on a tile, in the units the interaction system reads.
  ///
  /// It reads Flame's `position`, and entities are placed there in *pixels* by
  /// the same `gridToScreen` the doors use -- the conveyor on tile (0,6) sits at
  /// (-192,96). The party's position is the component's, so tile coordinates put
  /// it nowhere near anything: the first run of this test stood it at (0,6) and
  /// reported the conveyor broken when the two were 200 pixels apart in different
  /// coordinate spaces.
  void standOn(CharacterComponent character, double x, double y) {
    final screen = IsometricCoordinates.gridToScreen(Vector3(x, y, 0));
    character.position = screen;
  }

  testWidgets('an entity the party stands on fires, and floor does not', (
    tester,
  ) async {
    final party = await settle(tester);

    // --- the control -------------------------------------------------------
    // First, because it is what gives the second half its meaning. An assertion
    // that "the conveyor pushed the party" is satisfied by a system that pushes
    // the party everywhere, so bare floor has to move nothing.
    //
    // (0,6) is the conveyor and (7,7) the doughnut in castle_start; (7,9) is
    // between them.
    standOn(party.character, 7, 9);
    final onFloor = party.character.position.clone();
    for (var step = 0; step < steps; step++) {
      await withLoop(tester, party.loaded.game, () async {});
    }
    expect(
      party.character.position.distanceTo(onFloor),
      lessThan(0.001),
      reason:
          'standing on bare floor at 7,9 moved the party from $onFloor to '
          '${party.character.position}. If floor already pushes the party, a '
          'system that fired every entity everywhere would satisfy the next '
          'assertion too, and this test would be worth nothing.',
    );

    // --- the claim ---------------------------------------------------------
    //
    // The tile is read from the room rather than hard-coded, so a map edit
    // cannot leave this standing on a tile that is no longer a conveyor.
    final triggers = party.loaded.room.definition.triggers
        .where((t) => t.type.name == 'conveyor')
        .toList();
    expect(
      triggers,
      isNotEmpty,
      reason:
          'the starting room has no conveyor, so this would be about '
          'nothing',
    );
    final tile = triggers.first.position;

    standOn(party.character, tile.x, tile.y);
    final onConveyor = party.character.position.clone();
    var moved = false;
    for (var step = 0; step < steps; step++) {
      await withLoop(tester, party.loaded.game, () async {});
      if (party.character.position.distanceTo(onConveyor) > 0.001) {
        moved = true;
        break;
      }
    }

    expect(
      moved,
      isTrue,
      reason:
          'the party stood on the conveyor at ${tile.x},${tile.y} for $steps '
          'engine steps and did not move. Its onEnter is registered with the '
          'interaction system and pushes it as of T097; if this fails, nothing '
          'is registering entities again.',
    );
  });
}
