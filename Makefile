APP_NAME = Claude RC Manager
BUILD_DIR = .build/release
APP_DIR = $(BUILD_DIR)/$(APP_NAME).app

.PHONY: build test install uninstall reinstall stop start clean

# Builds the binary, assembles the .app bundle with all localizations,
# and signs it (ad-hoc).
build:
	swift build -c release
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	cp "$(BUILD_DIR)/ClaudeRCManager" "$(APP_DIR)/Contents/MacOS/ClaudeRCManager"
	mkdir -p "$(APP_DIR)/Contents/Resources"
	for lproj in "$(BUILD_DIR)/ClaudeRCManager_ClaudeRCManager.bundle/"*.lproj; do \
		cp -R "$$lproj" "$(APP_DIR)/Contents/Resources/"; \
	done
	for lang in en de fr es it ja zh-hans; do \
		test -f "$(APP_DIR)/Contents/Resources/$$lang.lproj/Localizable.strings" \
			|| { echo "missing $$lang.lproj/Localizable.strings"; exit 1; }; \
		cp "Resources/InfoPlist/$$lang.lproj/InfoPlist.strings" \
			"$(APP_DIR)/Contents/Resources/$$lang.lproj/"; \
	done
	codesign --force --sign - "$(APP_DIR)"
	@echo "Built: $(APP_DIR)"

test:
	swift test

install: build
	$(MAKE) uninstall
	cp -R "$(APP_DIR)" "/Applications/$(APP_NAME).app"
	@echo "Installed to /Applications/$(APP_NAME).app"

uninstall:
	@pgrep -x ClaudeRCManager >/dev/null && echo "Quit the app first (it stops its servers on quit)." && exit 1 || true
	rm -rf "/Applications/$(APP_NAME).app"
	@echo "Removed /Applications/$(APP_NAME).app"

# Graceful quit (the app stops its servers on quit; that takes up to ~6 s).
# Guarded by pgrep: an unguarded AppleScript quit would LAUNCH the app first.
stop:
	@if pgrep -x ClaudeRCManager >/dev/null; then \
		osascript -e 'tell application "$(APP_NAME)" to quit'; \
		for i in $$(seq 1 20); do \
			pgrep -x ClaudeRCManager >/dev/null || break; sleep 0.5; \
		done; \
	fi
	@pgrep -x ClaudeRCManager >/dev/null && { echo "app did not quit"; exit 1; } || echo "Stopped."

start:
	open "/Applications/$(APP_NAME).app"

# Full cycle: stop running instance, uninstall, build, install, launch.
# Explicit sub-makes: prerequisite order is not guaranteed under make -j.
reinstall:
	$(MAKE) stop
	$(MAKE) install
	$(MAKE) start

clean:
	rm -rf .build
