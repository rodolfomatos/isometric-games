.PHONY: setup run run-headoverheels run-knightlore serve-headoverheels serve-knightlore serve-editor run-editor build-headoverheels build-knightlore build-editor test test-packages test-coverage lint format format-check check assets-check assets-preview doctor help build build-release build-release-apk build-release-appbundle build-release-all build-version generate clean security-scan install verify-browser

# The repository holds two games and three libraries. Nothing at the top level is
# a package of its own, so every command names the directory it runs in.
GAMES := games/headoverheels games/knightlore
LIBRARIES := packages/iso_core packages/iso_editor
GAME := games/headoverheels

AES_LANGUAGE ?= flutter
AES_LINT ?= flutter analyze --no-fatal-infos --no-fatal-warnings
AES_TEST ?= flutter test
AES_FORMAT ?= dart format games packages
AES_BUILD ?= flutter build apk --release
AES_RUN ?= flutter run -d web-server

export AES_LANGUAGE AES_LINT AES_TEST AES_FORMAT AES_BUILD AES_RUN

setup:
	@echo "Setting up $(AES_LANGUAGE)..."
	@for dir in $(GAMES) $(LIBRARIES); do (cd $$dir && flutter pub get) || exit 1; done
	@cd packages/iso_builder_cli && dart pub get

run: run-headoverheels

run-headoverheels:
	@cd $(GAME) && $(AES_RUN) --web-port 8080

run-knightlore:
	@cd games/knightlore && $(AES_RUN) --web-port 8081

# Serves a game's web build the way a player would load it.
#
# `make run-<game>` is for working on the game: it serves a *debug* build, where
# the whole program is compiled in the browser as it loads, which is why running
# Knight Lore that way leaves a person on "Loading the castle" for minutes. These
# build first and serve the result, so what is on the screen is the game.
#
# The server is a foreground process: Ctrl-C stops it. The ports are the same ones
# `make run-<game>` uses, so the two cannot both be up at once.
serve: serve-headoverheels

serve-headoverheels:
	@$(MAKE) build-headoverheels
	@echo "Head over Heels, release build: http://localhost:8080 (Ctrl-C to stop)"
	@cd games/headoverheels/build/web && python3 -m http.server 8080

serve-knightlore:
	@$(MAKE) build-knightlore
	@echo "Knight Lore, release build: http://localhost:8081 (Ctrl-C to stop)"
	@cd games/knightlore/build/web && python3 -m http.server 8081

# The editor is a library that has an entry point, so it builds and serves like a
# game. Its map lives in the page: it can read and write Tiled files through the
# file gateway, and it keeps nothing between visits.
build-editor:
	@cd packages/iso_editor && flutter build web

run-editor:
	@cd packages/iso_editor && $(AES_RUN) --web-port 8082

serve-editor:
	@$(MAKE) build-editor
	@echo "Iso Editor, release build: http://localhost:8082 (Ctrl-C to stop)"
	@cd packages/iso_editor/build/web && python3 -m http.server 8082

build-headoverheels:
	@cd $(GAME) && flutter build web

build-knightlore:
	@cd games/knightlore && flutter build web

test:
	@cd $(GAME) && $(AES_TEST)

lint:
	@cd $(GAME) && $(AES_LINT)

format:
	@$(AES_FORMAT)

format-check:
	@dart format --output=none --set-exit-if-changed games packages

check: format-check lint test test-packages assets-check test-ai \
	gmif-check gmif-staleness art-content

test-packages:
	@cd packages/iso_core && flutter test
	@cd packages/iso_editor && flutter test
	@cd packages/iso_builder_cli && dart test
	@cd games/knightlore && flutter test

# What the games load, laid out to be looked at: every sprite sheet and every
# sound, in a page. Not a build of anything the games use.
assets-preview:
	@python3 scripts/asset_inventory.py

# What a browser is for, and what it is not for.
#
# It answers one question: does anything on the screen change. A build that
# draws a room with no party in it looks the same as one that draws a room with
# a party in it, and only a difference between two frames tells the two apart.
# The counts are in build/browser/*.png, read by scripts/browser_motion.py.
#
# It does NOT answer "where is the room drawn". Measured: a rectangle the game
# draws at canvas (0,0) lands in the page at x[666..1280] y[474..800], a scale
# of 1.535 in x and 1.087 in y, and the same numbers under four GL
# configurations and three window sizes. That factor is not distortion and it
# never was: it is the canvas letterboxed inside a wider, shorter page, with the
# margin in black. The mapping is a fixed affine, so
# `scripts/browser_canvas_geometry.js` inverts it and the harness's own plain
# canvas rectangle lands on the expected page pixel every time. An earlier
# version of this comment called the page unfaithful and pointed at the browser
# as the culprit; that was wrong, and it cost a day of browser-side geometry
# work before the browser was cleared. See aes/decisions/D001.md.
#
# What the browser still cannot do is read game state: pixel evidence says
# whether something was drawn, not what it is. Identity and composition come from
# the off-screen render in `flutter test`, which is what the render guards use.
#
# The gate is on Head over Heels only, and only because there is something there
# to move: its party is animated and its entities walk, so a still frame is a
# real fault. Knight Lore's room stands perfectly still while the party is
# standing still — the knight sprites have one frame and no idle cycle — so
# "nothing changed" there is the correct answer and failing on it would be
# failing on the game's own design. Its numbers are printed either way.
#
# Not part of `make check`, which does not build: this target builds two release
# web builds first, which is most of the cost. One run is about 40 seconds of
# driving plus the builds.
# Walks the game through its own map, in a real browser.
#
# Slow -- about four minutes of holding keys -- so it is not in `verify-browser`.
# It exits 2 when the renderer is too slow here to tell a broken door from a
# working one, which is what happens under software GL at about one frame per
# second. That is neither a pass nor a failure and the script says so in as many
# words. See T095.
walk:
	@python3 scripts/browser_walk.py

# The gate that drives the game. `make check` is fast and does not build; this
# builds two web bundles and opens them. It runs before a push, not before a save,
# and the reason is written here rather than left to whoever is in a hurry:
# `make check` was green through the party vanishing on every door.
verify-browser:
	@echo "Building the release web builds a player would load..."
	@$(MAKE) build-headoverheels build-knightlore
	@mkdir -p build/browser
	@echo ""
	@echo "Head over Heels: click into the game, then hold the virtual joystick."
	@DRAG=86,714,55,0 DRAG_AFTER=8000 node scripts/browser_check.js \
		games/headoverheels/build/web hoh 638,363 24000 8105 >/dev/null

	@echo "Knight Lore: click the title."
	@node scripts/browser_check.js games/knightlore/build/web kl 640,400 12000 8106 >/dev/null
	@echo ""
	@python3 scripts/browser_motion.py --fail-under 200 build/browser/hoh_*.png
	@echo ""
	@python3 scripts/browser_motion.py --report-only build/browser/kl_*.png
	@echo ""

	@echo ""
	@python3 scripts/browser_motion.py --fail-under 200 build/browser/hoh_*.png >/dev/null \
		&& echo "Head over Heels: the frame changes, so the game is alive." \
		|| (echo "Head over Heels: NOTHING ON THE SCREEN CHANGED. The game drew" \
		    "a frame and nothing in it is moving."; exit 1)
	@echo ""
	@echo "Captures and numbers in build/browser/."


# The deterministic half of the art pipeline: trim, anchor, palette snap. These
# are the steps that decide pixels, so they are the steps with tests.
test-ai:
	python3 -m pytest scripts/tests -q

# Five of the six AES skills ship as prose with no thresholds and no way to fail,
# so a phase that "passed" them proved nothing. These are the numbers they name.
# Exits non-zero on FAIL, and WARN does not fail the build on purpose: an absent
# knowledge base is a fact to record, not a fault to hide.
aes-check:
	python3 scripts/aes_metrics.py all

# The satisfiability gate for aes/graph/*.yaml. The skill's own gmif-check.sh
# reports SAT on islands Z3 rejected, so this one fails on anything that is not a
# clean sat or unsat. It used to stay out of `check` while T088 was open; with
# both islands satisfiable it is a gate like any other.
gmif-check:
	python3 scripts/gmif_check.py

# The skill's gmif-staleness-check.sh globs aes/shadow/SD-GMIF-*.md, which matches
# nothing here -- its six documents are SD-CI-* and SD-META-* -- and it reported
# "No STALE GMIF shadows" anyway. This one reads every dated shadow and treats
# zero documents examined as a failure, because a gate that cannot tell "nothing
# is stale" from "I read nothing" is not a gate.
gmif-staleness:
	python3 scripts/gmif_staleness.py

# Asks whether a sprite file contains art. Every other check in this repository
# asks whether it exists and decodes, which `door_master.png` -- a flat brown
# rectangle, 1021 bytes -- passes. T098.
art-content:
	python3 scripts/validate_art_content.py

assets-check:
	@python3 scripts/validation_pipeline.py $(GAME)
	@python3 scripts/validate_sprites.py $(GAME)
	@python3 scripts/publish_planet_tilesets.py --check
	@for game in $(GAMES); do python3 scripts/publish_assets.py $$game --check || exit 1; done

build:
	@cd $(GAME) && $(AES_BUILD)

# Release builds
build-release-apk:
	@echo "Building release APK..."
	@cd $(GAME) && flutter build apk --release --obfuscate --split-debug-info=build/debug_info

build-release-appbundle:
	@echo "Building release App Bundle (for Play Store)..."
	@cd $(GAME) && flutter build appbundle --release --obfuscate --split-debug-info=build/debug_info

build-release-all: build-release-appbundle build-release-apk

# Build with version from pubspec
build-version:
	@cd $(GAME) && flutter build apk --release --obfuscate --split-debug-info=build/debug_info --build-name=$$(grep '^version:' pubspec.yaml | cut -d' ' -f2 | cut -d'+' -f1) --build-number=$$(grep '^version:' pubspec.yaml | cut -d' ' -f2 | cut -d'+' -f2)

# Clean build artifacts
clean:
	@for dir in $(GAMES) $(LIBRARIES); do (cd $$dir && flutter clean) || exit 1; done
	@rm -rf packages/iso_builder_cli/build/
	@rm -rf build/ .dart_tool/
	@rm -rf $(GAME)/android/.gradle/ $(GAME)/android/app/build/

# Run code generation
generate:
	@cd $(GAME) && dart run build_runner build --delete-conflicting-outputs

# Run tests with coverage
test-coverage:
	@cd $(GAME) && flutter test --coverage
	@genhtml $(GAME)/coverage/lcov.info -o coverage/html

# Check for security issues
security-scan:
	@cd $(GAME) && $(AES_LINT)
	@echo "Checking for hardcoded secrets..."
	@! grep -r "password\|secret\|api_key" $(GAME)/lib/ --include="*.dart" | grep -v "YOUR_" | grep -v "// " || echo "Potential secrets found!"

# Install on connected device
install:
	@cd $(GAME) && flutter install --release

# Doctor check
doctor:
	@echo "Language: $(AES_LANGUAGE)"
	@echo "Flutter: $$(flutter --version 2>/dev/null | head -1 || echo not-found)"

# Help
help:
	@echo "AES Commands:"
	@echo "  make setup           - Install dependencies"
	@echo "  make run             - Run in debug mode"
	@echo "  make test            - Run tests"
	@echo "  make test-coverage   - Run tests with coverage"
	@echo "  make lint            - Run analyzer"
	@echo "  make format          - Format code"
	@echo "  make build           - Build debug APK"
	@echo "  make build-release-apk      - Build release APK"
	@echo "  make build-release-appbundle - Build release App Bundle (Play Store)"
	@echo "  make build-release-all      - Build both APK and App Bundle"
	@echo "  make build-version  - Build with version from pubspec"
	@echo "  make generate        - Run code generation"
	@echo "  make clean           - Clean build artifacts"
	@echo "  make security-scan   - Check for security issues"
	@echo "  make install         - Install release APK on device"
	@echo "  make doctor          - Show environment info"
	@echo "  make format-check    - Verify Dart formatting"
	@echo "  make test-packages   - Test builder packages"
	@echo "  make assets-check    - Validate sprite assets"
	@echo "  make verify-browser  - Release web builds in a real browser, counting pixels"
	@echo "  make check           - Run all checks"