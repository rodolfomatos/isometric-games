// Main game class for Head over Heels using Flame.

import '../../core/audio/hoh_cues.dart';
import 'dart:async';

import 'package:flame/game.dart';
import 'package:headoverheels/core/assets/sprite_registry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:headoverheels/features/gameplay/state/input_system.dart';
import 'package:headoverheels/features/gameplay/state/crowns_notifier.dart';
import 'package:headoverheels/features/gameplay/systems/interaction_system.dart';
import 'package:headoverheels/features/gameplay/entities/character_component.dart';
import 'package:headoverheels/features/gameplay/room/room_component.dart';
import 'package:headoverheels/features/gameplay/room/room_graph.dart';
import 'package:headoverheels/features/gameplay/room/world_loader.dart';
import 'package:headoverheels/features/gameplay/state/character_notifier.dart';
import 'package:headoverheels/features/audio/audio_system.dart';
import 'package:headoverheels/entities/character_state.dart';
import 'package:headoverheels/features/gameplay/entities/bag_entity.dart';
import 'package:headoverheels/features/gameplay/entities/crown_entity.dart';
import 'package:headoverheels/features/gameplay/entities/dropped_item_entity.dart';
import 'package:headoverheels/features/gameplay/entities/guardian_entity.dart';

/// Main game class that manages the game world and loop.
class HeadOverHeelsGame extends FlameGame
    implements
        BagCollector,
        CrownCollector,
        ItemPicker,
        GuardianDefeatedNotifier {
  final Ref ref;

  /// Set once the guardian is beaten, which is what opens the throne room.
  bool guardianDefeated = false;
  final WorldGraph _worldGraph;

  /// From the container, so the widget holding the keyboard and the game are
  /// looking at one instance and not two.
  late final InteractionSystem _interactionSystem;
  late final InputSystem _inputSystem;

  RoomComponent? _currentRoom;
  late RoomId _currentRoomId;
  String? _lastPlanetId;

  HeadOverHeelsGame(this.ref, this._worldGraph);

  @override
  Future<void> onLoad() async {
    await super.onLoad();

    // The same input system the touch controls write to. Building a second one
    // here would mean the joystick talking to an object the game never reads.
    _inputSystem = ref.read(inputSystemProvider);
    _interactionSystem = ref.read(interactionSystemProvider);

    // Load initial room from world graph
    _currentRoomId = _worldGraph.startRoom;
    await _loadRoom(_currentRoomId);

    // Add characters
    await _addCharacters();

    // Everything else the manifest lists arrives after the first frame, and
    // without holding the game up: the room is on screen, the party is on it, and
    // the props and effects land as they come. T065.
    unawaited(SpriteRegistry().initialize());

    // Set up camera
    _frameRoom();
  }

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    // The room is fitted to the window, so a resize has to fit it again.
    _frameRoom();
  }

  /// Puts the whole room in the view, centred.
  ///
  /// The room is drawn in world coordinates that reach into negative x — a
  /// sixteen-by-sixteen isometric room spans x from -512 to 512 — so a camera
  /// left at the origin shows the right half of the room and none of the left,
  /// and the party, which starts at the top-left corner of the room, is off the
  /// side of the screen. Measured, before this: the party drew 0 pixels.
  void _frameRoom() {
    final bounds = _currentRoom?.worldBounds;
    if (bounds == null || !hasLayout) return;
    final centre = bounds.center;
    camera.viewfinder.zoom = _zoomThatFits(
      Vector2(bounds.width, bounds.height),
    );
    camera.viewfinder.position = Vector2(centre.dx, centre.dy);
  }

  /// The largest zoom at which [room] still fits the window.
  double _zoomThatFits(Vector2 room) {
    if (room.x <= 0 || room.y <= 0) return 1;
    return (size.x / room.x < size.y / room.y
        ? size.x / room.x
        : size.y / room.y);
  }

  @override
  void update(double dt) {
    super.update(dt);

    // Update physics for both characters (fixed timestep handled internally)
    _inputSystem.updatePhysics(dt);

    // Update interactions
    _interactionSystem.update(dt);

    // Update current room entities
    _currentRoom?.update(dt);
  }

  /// Current room ID.
  RoomId get currentRoomId => _currentRoomId;

  /// Current room component.
  RoomComponent? get currentRoom => _currentRoom;

  /// Load a room by ID.
  Future<void> _loadRoom(RoomId roomId) async {
    final definition = _worldGraph.getRoom(roomId);
    if (definition == null) {
      throw StateError('Room not found: $roomId');
    }

    final previous = _currentRoom;

    // Create and load the new room while the old one is still standing.
    //
    // The order here is the whole fix. This used to unload first, and unloading
    // detached each character and then awaited `world.add` to re-attach it -- so
    // across that await the character had no parent at all, and a `FlameGame`
    // draws no tree but its own. The party blinked out for a frame on every
    // door. The original bug was the same shape with no window: it detached and
    // never re-attached, so the party was gone rather than blinking.
    final room = RoomComponent(
      roomId: roomId,
      definition: definition,
      interactionSystem: _interactionSystem,
    );
    // Into the world, not into the game. `FlameGame`'s camera draws the world
    // and nothing else, so a component added to the game itself never goes
    // through the camera: its world coordinates land straight on the canvas,
    // and the left half of every room, which is negative x, is off the side of
    // the screen. That is where the party went.
    await world.add(room);

    // Move the party across in one synchronous step. `removeCharacter` detaches
    // and `addCharacter` attaches, and there is no `await` between them, so the
    // party is parented before the step and parented after it and never
    // unattached in between. A copy of the list, because the first call removes
    // from the very list being walked -- which is the `ConcurrentModificationError`
    // this whole sequence was written to avoid.
    if (previous != null) {
      // The component tree is the truth, not `characters`. The list and the tree
      // disagree: a room loaded with a party in it reports an empty `characters`
      // while the party is a child of the room, so iterating the list moved
      // nobody and the party stayed in the room that was about to be torn down.
      final carried = previous.children
          .whereType<CharacterComponent>()
          .toList();
      for (final character in carried) {
        previous.removeCharacter(character);
        room.addCharacter(character);
      }
      // And if the room never held them, they are in the world, as they are
      // before the first room loads.
      if (carried.isEmpty) _moveCharactersToRoom(room);
    }

    // Only now is the old room torn down, with nobody in it.
    if (previous != null) {
      for (final entity in previous.entities.toList()) {
        // Unregister before removing. The interaction system holds its own list
        // and does not follow the component tree, so an entity left registered
        // keeps being overlap-tested against the party for the rest of the game
        // -- from a room that no longer exists.
        _interactionSystem.unregisterEntity(entity);
        entity.removeFromParent();
      }
      previous.removeFromParent();
    }

    _currentRoom = room;
    _currentRoomId = roomId;
    ref.read(crownsProvider.notifier).arriveOn(definition.theme);

    // Play music for the room's planet/theme
    _playRoomMusic(definition.theme);

    // Only the first room needs the characters found, because after this they
    // are always in a room and never in the world.
    if (previous == null) _moveCharactersToRoom(room);
    _frameRoom();
  }

  /// Play background music appropriate for the room theme.
  void _playRoomMusic(String theme) {
    final audioSystem = ref.read(audioSystemProvider);
    if (_lastPlanetId != theme) {
      _lastPlanetId = theme;
      audioSystem.playMusic(theme);
    }
  }

  /// Transition to a new room via an exit.
  Future<void> transitionTo(RoomId targetRoomId, String targetEntrance) async {
    final audioSystem = ref.read(audioSystemProvider);
    audioSystem.playTeleport();

    await _loadRoom(targetRoomId);

    // Position characters at entrance
    final entrance = _findEntrance(targetEntrance);
    if (entrance != null) {
      _positionCharactersAt(entrance);
    }
  }

  /// Move both characters to the current room.
  void _moveCharactersToRoom(RoomComponent room) {
    CharacterComponent? head;
    CharacterComponent? heels;

    // In the world, because that is where the game put them: looking in the
    // game's own children found nothing and the party was never moved into a
    // room at all.
    // Over the whole subtree, not `world.children`. The party is a child of a
    // room, which is a child of the world, so a search of the world's direct
    // children finds nobody and this method has never moved anyone.
    final found = <CharacterComponent>[];
    world.descendants().whereType<CharacterComponent>().forEach(found.add);
    for (final character in found) {
      if (character.type == CharacterType.head) {
        head = character;
      } else if (character.type == CharacterType.heels) {
        heels = character;
      }
    }

    if (head != null) room.addCharacter(head);
    if (heels != null) room.addCharacter(heels);
  }

  /// Position characters at a specific entrance point.
  void _positionCharactersAt(Vector3 gridPosition) {
    final headNotifier = ref.read(headProvider.notifier);
    final heelsNotifier = ref.read(heelsProvider.notifier);

    // Set positions directly (for room transitions)
    headNotifier.setPosition(gridPosition);
    heelsNotifier.setPosition(gridPosition + Vector3(1, 0, 0));
  }

  /// Find entrance position by name in current room.
  Vector3? _findEntrance(String entranceName) {
    // For now, use spawn point
    final definition = _worldGraph.getRoom(_currentRoomId);
    return definition?.spawnPoint;
  }

  /// The notifier behind a character, so a pickup can reach its state: the hand
  /// and the bag live in there.
  CharacterStateNotifier? notifierFor(CharacterComponent character) {
    final provider = character.type == CharacterType.head
        ? headProvider
        : heelsProvider;
    return ref.read(provider.notifier);
  }

  @override
  void onBagCollected(CharacterComponent character) {
    // The bag is worn. It used to be put in the hand as a fake item, which made
    // the one slot a character has hold a bag nobody could use, so the key on
    // the floor could no longer be picked up after the bag was.
    notifierFor(character)?.wearBag();
  }

  @override
  void collectCrown(String planetId) {
    ref.read(crownsProvider.notifier).collect(planetId);
  }

  @override
  void onItemPickedUp(CharacterComponent character, CarriedItem item) {
    notifierFor(character)?.pickUp(item);
  }

  /// How many crowns a planet has collected: its own, and no other's.
  int crownsFor(String planetId) =>
      ref.read(crownsProvider).byPlanet[planetId] ?? 0;

  @override
  void onGuardianDefeated() {
    guardianDefeated = true;
  }

  /// Add characters to the game world.
  Future<void> _addCharacters() async {
    // Head character
    final head = CharacterComponent(type: CharacterType.head, ref: ref);
    await world.add(head);
    _interactionSystem.registerCharacter(head);

    // Heels character
    final heels = CharacterComponent(type: CharacterType.heels, ref: ref);
    await world.add(heels);
    _interactionSystem.registerCharacter(heels);
  }

  /// Play a sound effect through the audio system.
  void playSfx(HohCue cue, {double? volume}) {
    ref.read(audioSystemProvider).playSfx(cue, volume: volume);
  }

  /// Convenience methods for common game sound effects.
  void playJump() => ref.read(audioSystemProvider).playJump();
  void playLand() => ref.read(audioSystemProvider).playLand();
  void playPickup() => ref.read(audioSystemProvider).playPickup();
  void playSwitch() => ref.read(audioSystemProvider).playSwitch();
  void playDoor() => ref.read(audioSystemProvider).playDoor();
  void playSpring() => ref.read(audioSystemProvider).playSpring();
  void playFire() => ref.read(audioSystemProvider).playFire();
  void playDoughnutHit() => ref.read(audioSystemProvider).playDoughnutHit();
  void playEnemyHit() => ref.read(audioSystemProvider).playEnemyHit();
  void playPlayerHit() => ref.read(audioSystemProvider).playPlayerHit();
  void playPlayerDeath() => ref.read(audioSystemProvider).playPlayerDeath();
  void playFishEat() => ref.read(audioSystemProvider).playFishEat();
  void playFishPoison() => ref.read(audioSystemProvider).playFishPoison();
  void playCrown() => ref.read(audioSystemProvider).playCrown();
  void playBag() => ref.read(audioSystemProvider).playBag();
  void playHushPuppy() => ref.read(audioSystemProvider).playHushPuppy();
  void playSwop() => ref.read(audioSystemProvider).playSwop();
}

/// Provider for WorldGraph loaded from JSON.
final worldGraphProvider = FutureProvider<WorldGraph>((ref) async {
  return loadWorldGraph();
});

/// The container's [Ref], for the widget layer to pass to the game.
///
/// A [WidgetRef] is a different type and does not fit where the game needs a
/// [Ref], so the screen reads this instead of trying to pass its own.
final gameRefProvider = Provider<Ref>((ref) => ref);

/// Builds the game over a world that is already loaded.
///
/// A provider for the game itself was a trap: the world arrives asynchronously,
/// so reading the provider before it resolved threw. The screen waits for
/// [worldGraphProvider] and calls this, which is the one way a game gets made.
HeadOverHeelsGame createHeadOverHeelsGame(Ref ref, WorldGraph worldGraph) =>
    HeadOverHeelsGame(ref, worldGraph);
