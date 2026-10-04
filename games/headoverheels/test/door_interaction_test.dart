// Pressing the action key beside a door opens it.
//
// T097 found that `onInteract` -- declared on `PuzzleEntity` as "presses action
// key while overlapping" -- had no caller anywhere in `lib/`. Twelve entity files
// implemented it: doors, chests, keys, dropped items, fish, the crown, the
// dispensary, the bag, the hush puppy. All of it was scenery that happened to be
// drawn. The party could stand on a door for sixty engine steps and nothing
// happened, because no key could reach an entity.
//
// This drives the same call a keypress reaches: `onActionPressed()`, which
// overlap-tests the party against the room's entities and acts on whatever it is
// standing next to. "Standing next to" is the same bounds test `_checkInteraction`
// uses, deliberately -- two notions of adjacent would mean a key press that does
// nothing beside a thing the game believes you are touching.
//
// The order here matters. The party is placed next to the door and stepped for a
// while *first*, and the room must not change. A door that opened on approach
// would satisfy a test that only pressed the key, and that is a different game.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:headoverheels/core/isometric.dart';
import 'package:headoverheels/features/gameplay/entities/character_component.dart';
import 'package:headoverheels/features/gameplay/room/room_graph.dart'
    show ExitDirection, TriggerType;
import 'package:headoverheels/features/gameplay/systems/interaction_system.dart';
import 'package:vector_math/vector_math.dart' show Vector3;

import 'support/hoh_frame.dart';

/// Engine steps given to each observation.
const int steps = 10;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the action key opens the door the party is standing beside', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final loaded = await loadRealGame(tester);
    expect(loaded, isNotNull, reason: 'the game never finished loading');
    final game = loaded!.game;
    freeze(game);

    final startId = game.currentRoomId;
    final room = loaded.room;
    final doors = room.definition.triggers
        .where((t) => t.type == TriggerType.door && t.exit != null)
        .toList();
    expect(
      doors,
      isNotEmpty,
      reason:
          '$startId declares no door trigger. If the map has exits and no '
          'doors, that disagreement is itself the finding.',
    );

    final door = doors.first;
    final exit = door.exit!;
    final tile = Vector3(door.position.x, door.position.y, door.position.z);

    // The tile beside the door, on the side the party would come from.
    final beside = switch (exit.direction) {
      ExitDirection.east => Vector3(tile.x - 1, tile.y, tile.z),
      ExitDirection.west => Vector3(tile.x + 1, tile.y, tile.z),
      ExitDirection.north => Vector3(tile.x, tile.y - 1, tile.z),
      ExitDirection.south => Vector3(tile.x, tile.y + 1, tile.z),
      final other => fail(
        '$startId has a door facing $other, which this test '
        'does not know how to stand beside',
      ),
    };

    // Flame's `position`, in pixels -- the space `_syncFromState` writes and the
    // space the entities are in. Standing at (15,8) in tile units put the party
    // nowhere near the door and looked like a dead door.
    void standBeside(Vector3 at) {
      final screen = IsometricCoordinates.gridToScreen(at);
      for (final character in loaded.party) {
        character.position = screen;
      }
    }

    standBeside(beside);
    for (var step = 0; step < steps; step++) {
      await withLoop(tester, game, () async {});
    }
    expect(
      game.currentRoomId,
      startId,
      reason:
          'standing beside the door at $beside changed rooms by itself. A '
          'door that opens on approach is a different game from one you open, '
          'and the rest of this test would prove nothing.',
    );

    // The action key, by the call it reaches.
    final acted = game.ref.read(interactionSystemProvider).onActionPressed();
    expect(
      acted,
      greaterThan(0),
      reason:
          'the action key beside the door at $beside reached no entity. '
          'Nothing is registered with the interaction system, or the bounds do '
          'not overlap at this tile.',
    );

    var arrived = false;
    for (var step = 0; step < 60; step++) {
      await withLoop(tester, game, () async {});
      if (game.currentRoomId != startId) {
        arrived = true;
        break;
      }
    }

    expect(
      arrived,
      isTrue,
      reason:
          'the action key was pressed beside the door at $beside, which the '
          'map says leads to ${exit.targetRoom} by ${exit.targetEntrance}, and '
          'the room did not change.',
    );
    expect(
      game.currentRoomId,
      exit.targetRoom,
      reason: 'the party went through the door and landed somewhere else',
    );
  });
}
