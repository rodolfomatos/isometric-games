// Interaction system for Head over Heels.

import 'dart:ui' show Rect;
import 'package:flame/components.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:headoverheels/features/gameplay/entities/character_component.dart';
import 'package:headoverheels/features/gameplay/entities/puzzle_entity.dart';

/// Central system for handling character-entity interactions.
class InteractionSystem {
  final List<CharacterComponent> _characters = [];
  final List<PuzzleEntity> _entities = [];

  /// Register a character for interaction tracking.
  void registerCharacter(CharacterComponent character) {
    if (!_characters.contains(character)) {
      _characters.add(character);
    }
  }

  /// Unregister a character.
  void unregisterCharacter(CharacterComponent character) {
    _characters.remove(character);
  }

  /// Register an entity for interaction tracking.
  void registerEntity(PuzzleEntity entity) {
    if (!_entities.contains(entity)) {
      _entities.add(entity);
    }
  }

  /// Unregister an entity.
  void unregisterEntity(PuzzleEntity entity) {
    _entities.remove(entity);
  }

  /// Update all interactions (call every frame).
  void update(double dt) {
    for (final character in _characters) {
      for (final entity in _entities) {
        _checkInteraction(character, entity);
      }
    }
  }

  /// Acts on whatever the party is standing next to, right now.
  ///
  /// `onEnter` fires when the party walks into something. This fires when the
  /// player asks, which is a different act: a door is meant to be opened beside,
  /// on purpose, not by walking into it and finding out.
  ///
  /// Nothing called this. `onInteract` is declared on `PuzzleEntity` as "presses
  /// action key while overlapping", implemented by twelve entity files, and
  /// reachable only from tests -- so every door, chest, key and the crown were
  /// scenery that happened to be drawn.
  ///
  /// Overlapping is the same test `_checkInteraction` uses, on purpose: two
  /// different notions of "adjacent" would mean a key press that does nothing
  /// beside a thing the game thinks you are touching.
  int onActionPressed() {
    var acted = 0;
    for (final character in _characters.toList()) {
      for (final entity in _entities.toList()) {
        if (_getBounds(character).overlaps(_getBounds(entity))) {
          entity.onInteract(character);
          acted++;
        }
      }
    }
    return acted;
  }

  void _checkInteraction(CharacterComponent character, PuzzleEntity entity) {
    // Simple AABB collision check using position and size
    // This avoids relying on Flame's internal hitbox API
    final characterRect = _getBounds(character);
    final entityRect = _getBounds(entity);

    final colliding = characterRect.overlaps(entityRect);

    if (colliding) {
      if (!_CollisionTracker.wasColliding(entity, character)) {
        _CollisionTracker.setColliding(entity, character, true);
        entity.onEnter(character);
      }
    } else {
      if (_CollisionTracker.wasColliding(entity, character)) {
        _CollisionTracker.setColliding(entity, character, false);
        entity.onExit(character);
      }
    }
  }

  Rect _getBounds(PositionComponent component) {
    return Rect.fromLTWH(
      component.position.x - component.size.x / 2,
      component.position.y - component.size.y / 2,
      component.size.x,
      component.size.y,
    );
  }
}

/// Helper class to track collision state per entity.
class _CollisionTracker {
  static final Map<PuzzleEntity, Map<int, bool>> _collisions = {};

  static bool wasColliding(PuzzleEntity entity, CharacterComponent character) {
    return _collisions[entity]?[character.hashCode] ?? false;
  }

  static void setColliding(
    PuzzleEntity entity,
    CharacterComponent character,
    bool colliding,
  ) {
    _collisions.putIfAbsent(entity, () => {});
    if (colliding) {
      _collisions[entity]![character.hashCode] = true;
    } else {
      _collisions[entity]!.remove(character.hashCode);
    }
  }
}

/// The one interaction system the game and the widget both read.
///
/// The game used to build its own with `InteractionSystem()`, and the widget that
/// holds the keyboard had no way to reach it -- `onInteract` had no caller, and
/// `registerEntity` had none either. Two owners is the same bug as zero owners:
/// a shared mutable thing that nobody can get at. One owner, in the container,
/// read by both, is what makes "press E beside a door" a thing the game can do.
final interactionSystemProvider = Provider<InteractionSystem>(
  (ref) => InteractionSystem(),
);
