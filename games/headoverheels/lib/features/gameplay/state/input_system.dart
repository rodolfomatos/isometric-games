// Input system for Head over Heels - connects touch controls to character state.

import 'dart:ui' show Offset;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:headoverheels/core/isometric.dart';
import 'package:headoverheels/entities/character_state.dart';
import 'package:headoverheels/features/gameplay/state/character_notifier.dart';
import 'package:headoverheels/features/gameplay/state/dual_character_notifier.dart';

/// Service that processes input and updates character state.
class InputSystem {
  final Ref ref;

  InputSystem(this.ref);

  /// The direction a joystick offset names, or null for a centred stick.
  static Direction8? directionOfOffset(Offset offset) =>
      _offsetToDirection(offset);

  /// Convert normalized joystick offset (-1..1) to Direction8.
  static Direction8? _offsetToDirection(Offset offset) {
    if (offset == Offset.zero) return null;

    // `+ pi/2`, and the sign is the whole story. `Direction8.values` starts at
    // north and counts clockwise, so `fromAngle` reads 0 as north. A screen
    // offset is 0 for a push to the east, which is a quarter turn away from north.
    //
    // There used to be a `- pi/2` here, labelled "rotate so up = north". It is a
    // half turn, so it pointed every direction at its opposite:
    //
    //     push up    -> south
    //     push right -> west
    //     push down  -> north
    //     push left  -> east
    //
    // The joystick has been backwards for as long as it has existed. Nothing
    // caught it because nothing asserted which direction a push produced: the
    // party moved and the frame changed, and those were the only two things
    // anyone asked.
    return Direction8.fromAngle(offset.direction + 3.14159265359 / 2);
  }

  /// Get the currently controlled character notifier.
  CharacterStateNotifier? get _controlledNotifier {
    final dualState = ref.read(dualCharacterProvider);
    final controlled = dualState.controlled;

    if (controlled == ControlledEntity.head ||
        controlled == ControlledEntity.combined) {
      return ref.read(headProvider.notifier);
    } else if (controlled == ControlledEntity.heels) {
      return ref.read(heelsProvider.notifier);
    }
    return null;
  }

  /// The direction a set of held keys asks for, in the joystick's own
  /// coordinates: x east, y south, each in -1..1.
  ///
  /// Returned rather than applied so it can be tested without a keyboard, which
  /// is the only way this could have been tested at all before it existed.
  ///
  /// Diagonals are normalised. A joystick cannot be pushed further than its
  /// radius, and an unnormalised diagonal would move at sqrt(2) times the speed,
  /// which is a bug that looks like "diagonal movement feels fast".
  static Offset? directionFromKeys(Set<LogicalKeyboardKey> held) {
    var x = 0.0, y = 0.0;
    for (final key in held) {
      if (_upKeys.contains(key)) y -= 1;
      if (_downKeys.contains(key)) y += 1;
      if (_leftKeys.contains(key)) x -= 1;
      if (_rightKeys.contains(key)) x += 1;
    }
    if (x == 0 && y == 0) return null;
    final length = x != 0 && y != 0 ? 1.4142135623730951 : 1.0;
    return Offset(x / length, y / length);
  }

  /// Keys that move the party, as a direction each.
  // `static final`, not `static const`: `LogicalKeyboardKey` overrides `==`, so
  // it cannot be a key in a constant map, and lookups by identity would miss.
  static final Map<LogicalKeyboardKey, List<int>> _directionByKey = {
    LogicalKeyboardKey.arrowUp: [0, -1],
    LogicalKeyboardKey.keyW: [0, -1],
    LogicalKeyboardKey.arrowDown: [0, 1],
    LogicalKeyboardKey.keyS: [0, 1],
    LogicalKeyboardKey.arrowLeft: [-1, 0],
    LogicalKeyboardKey.keyA: [-1, 0],
    LogicalKeyboardKey.arrowRight: [1, 0],
    LogicalKeyboardKey.keyD: [1, 0],
  };

  static final Set<LogicalKeyboardKey> _upKeys = _directionByKey.entries
      .where((e) => e.value[1] < 0)
      .map((e) => e.key)
      .toSet();
  static final Set<LogicalKeyboardKey> _downKeys = _directionByKey.entries
      .where((e) => e.value[1] > 0)
      .map((e) => e.key)
      .toSet();
  static final Set<LogicalKeyboardKey> _leftKeys = _directionByKey.entries
      .where((e) => e.value[0] < 0)
      .map((e) => e.key)
      .toSet();
  static final Set<LogicalKeyboardKey> _rightKeys = _directionByKey.entries
      .where((e) => e.value[0] > 0)
      .map((e) => e.key)
      .toSet();

  static final Map<LogicalKeyboardKey, String> _actions = {
    LogicalKeyboardKey.space: 'jump',
    LogicalKeyboardKey.keyZ: 'jump',
    LogicalKeyboardKey.keyX: 'carry',
    LogicalKeyboardKey.keyC: 'carry',
    LogicalKeyboardKey.keyV: 'fire',
    LogicalKeyboardKey.keyF: 'fire',
    LogicalKeyboardKey.tab: 'swop',
    LogicalKeyboardKey.keyQ: 'swop',
    // Not in this table before, and its absence is why nothing in the game was
    // interactive: `onInteract` had no key that could reach it.
    LogicalKeyboardKey.keyE: 'interact',
    LogicalKeyboardKey.enter: 'interact',
  };

  /// Whether [key] is one of the direction keys this system listens for.
  static bool isDirectionKey(LogicalKeyboardKey key) =>
      _directionByKey.containsKey(key);

  /// The action a key asks for, or null if it asks for nothing.
  ///
  /// One key per action, and the choice is arbitrary: what matters is that the
  /// same key always does the same thing and that it is written down, because a
  /// player learns it in the first ten seconds.
  static String? actionForKey(LogicalKeyboardKey key) => _actions[key];

  /// Handle joystick direction change.
  void onJoystickDirection(Offset offset) {
    final notifier = _controlledNotifier;
    if (notifier == null) return;

    final direction = directionOfOffset(offset);
    if (direction != null) {
      notifier.move(direction);
    } else {
      notifier.stop();
    }
  }

  /// Handle jump action.
  void onJump() {
    final notifier = _controlledNotifier;
    notifier?.jump();
  }

  /// Handle carry action.
  void onCarry() {
    final notifier = _controlledNotifier;
    notifier?.carry();
  }

  /// Handle fire action.
  void onFire() {
    final notifier = _controlledNotifier;
    notifier?.fire();
  }

  /// Handle swop action - switch control between Head and Heels.
  void onSwop() {
    ref.read(dualCharacterProvider.notifier).swop();
  }

  /// Update physics for both characters (called from game loop).
  void updatePhysics(double dt) {
    ref.read(headProvider.notifier).update(dt);
    ref.read(heelsProvider.notifier).update(dt);

    // Sync dual character state
    final headState = ref.read(headProvider);
    final heelsState = ref.read(heelsProvider);
    ref
        .read(dualCharacterProvider.notifier)
        .syncFromNotifiers(headState, heelsState);
  }
}

/// Provider for InputSystem.
final inputSystemProvider = Provider<InputSystem>((ref) {
  return InputSystem(ref);
});
