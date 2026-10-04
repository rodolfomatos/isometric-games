// Game screen for Head over Heels.

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:headoverheels/features/gameplay/game.dart';
import 'package:headoverheels/features/ui/theme/app_theme.dart';
import 'package:headoverheels/features/ui/widgets/virtual_joystick.dart';
import 'package:headoverheels/features/ui/widgets/action_buttons.dart';
import 'package:headoverheels/features/ui/widgets/hud.dart';
import 'package:headoverheels/features/gameplay/room/room_graph.dart';
import 'package:headoverheels/features/gameplay/state/input_system.dart';
import 'package:headoverheels/features/gameplay/systems/interaction_system.dart';
import 'package:headoverheels/features/audio/audio_system.dart';
import 'package:headoverheels/features/audio/audio_settings.dart';

class GameScreen extends ConsumerStatefulWidget {
  static const routeName = '/game';

  const GameScreen({super.key, this.continueGame = false});

  final bool continueGame;

  @override
  ConsumerState<GameScreen> createState() => _GameScreenState();
}

/// What the canvas area says while there is no game to draw.
class _CanvasMessage extends StatelessWidget {
  const _CanvasMessage({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: AppColors.darkBackground,
    child: Center(
      child: Text(text, style: const TextStyle(color: Colors.white54)),
    ),
  );
}

class _GameScreenState extends ConsumerState<GameScreen> {
  bool _showPauseMenu = false;

  /// The game, built once the world has arrived. Held here so it survives
  /// rebuilds and can be disposed when the screen goes.
  HeadOverHeelsGame? _game;

  /// Kept so the music can be stopped on the way out: Riverpod does not allow
  /// a read in dispose().
  AudioSystem? _audioSystem;

  @override
  void initState() {
    super.initState();
    // Initialize audio system and play music
    _initAudio();
    // Initialize game state
    if (widget.continueGame) {
      // Load saved game
    } else {
      // Start new game
    }
  }

  Future<void> _initAudio() async {
    final audioSystem = ref.read(audioSystemProvider);
    _audioSystem = audioSystem;
    final settings = await ref.read(audioSettingsProvider.future);

    await audioSystem.initialize();
    audioSystem.setMusicEnabled(settings.musicEnabled);
    audioSystem.setSfxEnabled(settings.sfxEnabled);
    audioSystem.setMusicVolume(settings.musicVolume);
    audioSystem.setSfxVolume(settings.sfxVolume);
  }

  @override
  void dispose() {
    // The audio system is a plain object held by the container, not a widget,
    // so the music keeps playing between screens unless it is told to stop.
    // Riverpod forbids reading ref in here, so the reference is kept from when
    // the screen was alive.
    _audioSystem?.pauseMusic();
    // The game owns components, sprites and listeners, and GameWidget does not
    // dispose a game it was handed.
    _game?.dispose();
    super.dispose();
  }

  /// Builds the game the first time the world arrives, and only once: a new
  /// game would throw away the party's position and every loaded sprite.
  HeadOverHeelsGame _gameFor(WorldGraph world) =>
      _game ??= createHeadOverHeelsGame(ref.read(gameRefProvider), world);

  @override
  Widget build(BuildContext context) {
    final pauseOverlay = _showPauseMenu
        ? _buildPauseOverlay()
        : const SizedBox.shrink();

    final inputSystem = ref.watch(inputSystemProvider);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          setState(() => _showPauseMenu = true);
          ref.read(audioSystemProvider).playPause();
        }
      },
      child: Scaffold(
        body: _KeyboardControls(
          child: Stack(
            children: [
              // The game itself. The world arrives asynchronously, so until it
              // does there is nothing to put in here.
              _buildGameCanvas(),

              // HUD
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(child: HUD()),
              ),

              // The keys, said out loud. A feature nobody can discover is a
              // feature with no users.
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(child: KeyHints()),
              ),

              // Touch controls
              Positioned(
                bottom: AppSpacing.lg,
                left: AppSpacing.md,
                child: VirtualJoystick(
                  radius: 70,
                  onDirectionChanged: (direction) {
                    inputSystem.onJoystickDirection(direction);
                  },
                  onTap: () {
                    // Handle tap (could be jump)
                    inputSystem.onJump();
                  },
                ),
              ),

              Positioned(
                bottom: AppSpacing.lg,
                right: AppSpacing.md,
                child: ActionButtons(
                  onJump: () => inputSystem.onJump(),
                  onCarry: () => inputSystem.onCarry(),
                  onFire: () => inputSystem.onFire(),
                  onSwop: () => inputSystem.onSwop(),
                  canJump: true,
                  canCarry: true,
                  canFire: true,
                  canSwop: true,
                  doughnutCount: 3,
                ),
              ),

              // Pause button
              Positioned(
                top: AppSpacing.md,
                right: AppSpacing.md,
                child: PauseButton(
                  onPressed: () => setState(() => _showPauseMenu = true),
                ),
              ),

              // Pause menu overlay
              pauseOverlay,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGameCanvas() {
    final world = ref.watch(worldGraphProvider);
    return world.when(
      loading: () => const _CanvasMessage(
        key: Key('game-loading'),
        text: 'Loading the castle\u2026',
      ),
      error: (error, stack) => _CanvasMessage(
        key: const Key('game-error'),
        text: 'Could not load the world: $error',
      ),
      data: (graph) => GameWidget<HeadOverHeelsGame>(
        key: const Key('game-canvas'),
        game: _gameFor(graph),
        backgroundBuilder: (context) =>
            ColoredBox(color: AppColors.darkBackground),
      ),
    );
  }

  Widget _buildPauseOverlay() {
    return Container(
      color: Colors.black.withValues(alpha: 0.7),
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(AppSpacing.xl),
          padding: const EdgeInsets.all(AppSpacing.xl),
          decoration: BoxDecoration(
            color: AppColors.darkSurface,
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: AppColors.darkBorder),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Paused', style: AppTypography.h1),
              const SizedBox(height: AppSpacing.xl),
              _buildPauseButton('Resume', Icons.play_arrow_rounded, () {
                setState(() => _showPauseMenu = false);
                ref.read(audioSystemProvider).resumeMusic();
              }),
              const SizedBox(height: AppSpacing.md),
              _buildPauseButton('Restart Room', Icons.refresh_rounded, () {
                setState(() => _showPauseMenu = false);
              }),
              const SizedBox(height: AppSpacing.md),
              _buildPauseButton('Settings', Icons.settings_rounded, () {
                setState(() => _showPauseMenu = false);
                Navigator.of(context).pushNamed('/settings');
              }),
              const SizedBox(height: AppSpacing.md),
              _buildPauseButton('Quit to Menu', Icons.exit_to_app_rounded, () {
                ref.read(audioSystemProvider).playMusic('main_menu');
                Navigator.of(
                  context,
                ).pushNamedAndRemoveUntil('/main-menu', (route) => false);
              }, isDestructive: true),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPauseButton(
    String label,
    IconData icon,
    VoidCallback onPressed, {
    bool isDestructive = false,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: isDestructive
          ? OutlinedButton.icon(
              icon: Icon(icon),
              label: Text(label),
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.darkDestructive,
                side: BorderSide(color: AppColors.darkDestructive, width: 2),
              ),
            )
          : ElevatedButton.icon(
              icon: Icon(icon),
              label: Text(label),
              onPressed: onPressed,
            ),
    );
  }
}

/// Turns key presses into the same calls the joystick makes.
///
/// Without this the game had no keyboard at all: the joystick and the on-screen
/// buttons moved the party and no key did anything, so a player who reached for
/// the arrow keys stood still in a room that was otherwise alive.
///
/// Direction is accumulated from the held keys and normalised, because a joystick
/// cannot be pushed past its radius and an unnormalised diagonal would move at
/// sqrt(2) times the speed. `InputSystem.directionFromKeys` owns that arithmetic
/// and is testable without a keyboard, which this widget is not.
class _KeyboardControls extends ConsumerStatefulWidget {
  const _KeyboardControls({required this.child});

  final Widget child;

  @override
  ConsumerState<_KeyboardControls> createState() => _KeyboardControlsState();
}

class _KeyboardControlsState extends ConsumerState<_KeyboardControls> {
  final Set<LogicalKeyboardKey> _held = {};

  /// A hardware-level handler rather than a `Focus`.
  ///
  /// `Focus` only sees a key while it holds the focus, and this screen is a
  /// canvas and some buttons, so the keyboard worked by accident of being the only
  /// focusable thing. The moment anything else took focus -- the pause overlay, a
  /// route, a text field in a future dialog -- a player holding the right arrow
  /// would get nothing, with no indication the key was ever received.
  ///
  /// `HardwareKeyboard.addHandler` does not care who holds focus. It cannot be
  /// "taken away", so the failure mode is removed rather than reported.
  late final VoidCallback _register;
  bool _handling = false;

  @override
  void initState() {
    super.initState();
    final keyboard = HardwareKeyboard.instance;
    keyboard.addHandler(_onKeyEvent);
    _register = () => keyboard.removeHandler(_onKeyEvent);
  }

  @override
  void dispose() {
    _register();
    super.dispose();
  }

  bool _onKeyEvent(KeyEvent event) {
    if (_handling) return false;
    _handling = true;
    try {
      return _onKey(event);
    } finally {
      _handling = false;
    }
  }

  void _applyDirection() {
    final input = ref.read(inputSystemProvider);
    input.onJoystickDirection(
      InputSystem.directionFromKeys(_held) ?? Offset.zero,
    );
  }

  void _act(String action) {
    final input = ref.read(inputSystemProvider);
    switch (action) {
      case 'jump':
        input.onJump();
      case 'carry':
        input.onCarry();
      case 'fire':
        input.onFire();
      case 'swop':
        input.onSwop();
      case 'interact':
        // The one path from a keypress to an entity. It did not exist, which is
        // why a door could be walked into indefinitely.
        ref.read(interactionSystemProvider).onActionPressed();
    }
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyUpEvent) {
      // A repeat is the OS saying "still held", and the direction already says
      // so. Acting on it would re-fire every action key at the key-repeat rate.
      return false;
    }
    final key = event.logicalKey;
    final action = InputSystem.actionForKey(key);

    if (event is KeyDownEvent && action != null) {
      _act(action);
      return true;
    }
    if (!InputSystem.isDirectionKey(key)) return false;

    if (event is KeyDownEvent) {
      _held.add(key);
    } else {
      _held.remove(key);
    }
    _applyDirection();
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The key hints, said out loud.
///
/// A player has to be told the keys exist before they can find them, and a
/// feature nobody can discover is a feature with no users. The game had no
/// keyboard until T083 and nothing on screen has ever said so.
class KeyHints extends StatelessWidget {
  const KeyHints({super.key});

  static const _keys = [
    ('arrows / WASD', 'move'),
    ('space / Z', 'jump'),
    ('X / C', 'carry'),
    ('V / F', 'fire'),
    ('tab / Q', 'swop'),
  ];

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Opacity(
        opacity: 0.5,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 16,
            children: [
              for (final (keys, what) in _keys)
                Text(
                  '$keys $what',
                  style: const TextStyle(fontSize: 10, color: Colors.white),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
