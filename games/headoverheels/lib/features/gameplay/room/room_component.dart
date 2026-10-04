// Room component for Head over Heels.

import 'dart:ui' show Rect;

import 'package:flame/components.dart';
import 'package:flame_tiled/flame_tiled.dart';
import 'package:headoverheels/core/isometric.dart';
import 'package:headoverheels/features/gameplay/entities/character_component.dart';
import 'package:headoverheels/features/gameplay/entities/entity_factory.dart';
import 'package:headoverheels/features/gameplay/entities/puzzle_entity.dart';
import 'package:headoverheels/features/gameplay/systems/interaction_system.dart';
import 'package:headoverheels/features/gameplay/room/room_graph.dart';

/// Room component that manages a single room's tilemap and entities.
class RoomComponent extends PositionComponent with HasGameReference {
  final RoomId roomId;
  final RoomDefinition definition;
  TiledComponent? _tiledComponent;
  RenderableTiledMap? _tileMap;
  final List<PuzzleEntity> entities = [];
  final List<CharacterComponent> characters = [];
  RoomState _state;

  /// The system that hands a character to an entity when they overlap.
  ///
  /// Optional, and it has to be: a room built without one is a room whose
  /// entities nobody can ever touch. It was missing altogether for the whole
  /// game -- `registerEntity` existed and nothing called it, so
  /// `InteractionSystem._entities` was empty and no `onEnter` was ever fired.
  final InteractionSystem? interactionSystem;

  RoomComponent({
    required this.roomId,
    required this.definition,
    this.interactionSystem,
    RoomState? initialState,
  }) : _state = initialState ?? RoomState.initial(roomId);

  @override
  Future<void> onLoad() async {
    // Load TMX tilemap
    _tiledComponent = await TiledComponent.load(
      definition.tmxFile,
      Vector2(IsometricCoordinates.tileWidth, IsometricCoordinates.tileHeight),
      // The world's file paths already start at the bundle root, and
      // flame_tiled would otherwise put "assets/tiles/" in front of them, which
      // is a path that has never existed.
      prefix: '',
    );
    _tileMap = _tiledComponent!.tileMap;
    // Put the map at the origin of the space everything else is drawn in.
    //
    // `flame_tiled` places a right-down isometric map at its own local origin,
    // which is the top corner of its bounding box, and this game's positions
    // come from `gridToScreen`, where a room spans x from -(height-1)*32 to
    // (width-1)*32 + tileWidth. Those are the same room in two coordinate
    // systems, a room-width apart, so the map was drawn to the right of every
    // entity standing on it and the camera framed the space none of it was in.
    // The offset is the map's own extent and nothing else, so it is read from
    // the map rather than written down.
    final bounds = worldBounds;
    if (bounds != null) {
      _tiledComponent!.position = Vector2(bounds.left, bounds.top);
    }
    add(_tiledComponent!);

    // Spawn entities from triggers
    await _spawnEntities();

    super.onLoad();
  }

  Future<void> _spawnEntities() async {
    final spawned = <PuzzleEntity>[];
    for (final trigger in definition.triggers) {
      final entity = EntityFactory.create(trigger, roomId);
      if (entity != null) spawned.add(entity);
    }

    // Draw order is by renderPriority, not by trigger order. The map index is
    // carried along and compared second, so two entities of the same priority
    // keep the order the map declared and a room stays reproducible.
    final ordered = spawned.asMap().entries.toList()
      ..sort((a, b) {
        final byPriority = a.value.renderPriority.compareTo(
          b.value.renderPriority,
        );
        return byPriority != 0 ? byPriority : a.key.compareTo(b.key);
      });

    for (final entry in ordered) {
      entities.add(entry.value);
      add(entry.value);
      // A room full of entities the interaction system has never heard of is a
      // room full of scenery. This one line is why walking onto a conveyor used
      // to do nothing.
      interactionSystem?.registerEntity(entry.value);
    }
  }

  /// Get current room state.
  RoomState get state => _state;

  /// Update room state (called when room is saved).
  void updateState(RoomState newState) {
    _state = newState;
  }

  /// Get entity by ID.
  PuzzleEntity? getEntity(String id) {
    for (final entity in entities) {
      if (entity.id == id) return entity;
    }
    return null;
  }

  /// Get all entities of a specific type.
  List<T> getEntities<T extends PuzzleEntity>() {
    return entities.whereType<T>().toList();
  }

  /// Add character to room.
  void addCharacter(CharacterComponent character) {
    characters.add(character);
    add(character);
  }

  /// Remove character from room.
  void removeCharacter(CharacterComponent character) {
    characters.remove(character);
    character.removeFromParent();
  }

  @override
  void update(double dt) {
    super.update(dt);

    // Update puzzle entities
    for (final entity in entities) {
      entity.updatePuzzle(dt);
    }
  }

  /// Check if position is walkable (not a wall).
  bool isWalkable(Vector3 gridPos) {
    if (_tileMap == null) return true;

    // Check walls layer (layer index 1 typically)
    final wallsLayer = _tileMap!.getLayer<TileLayer>('Walls');
    if (wallsLayer != null && wallsLayer.id != null) {
      final gid = _tileMap!.getTileData(
        layerId: wallsLayer.id!,
        x: gridPos.x.toInt(),
        y: gridPos.y.toInt(),
      );
      return gid == null; // null = no tile = walkable
    }
    return true;
  }

  /// Get tile at grid position from any layer.
  Gid? getTileAt(String layerName, int x, int y) {
    final layer = _tileMap?.getLayer<TileLayer>(layerName);
    if (layer == null || layer.id == null) return null;
    return _tileMap!.getTileData(layerId: layer.id!, x: x, y: y);
  }

  /// The rectangle this room covers in world coordinates, or null before the
  /// map has loaded.
  ///
  /// The room is drawn by `flame_tiled` in the game's own isometric
  /// coordinates, so the box is the projection of the tile grid: wide and short,
  /// and reaching into negative x, which is why a camera at the origin shows
  /// the right half of a room and none of the left.
  Rect? get worldBounds {
    final map = _tileMap?.map;
    if (map == null) return null;
    final lastX = map.width - 1;
    final lastY = map.height - 1;
    final halfWidth = map.tileWidth / 2;
    final halfHeight = map.tileHeight / 2;
    return Rect.fromLTRB(
      -lastY * halfWidth,
      0,
      lastX * halfWidth + map.tileWidth,
      (lastX + lastY) * halfHeight + map.tileHeight,
    );
  }
}
