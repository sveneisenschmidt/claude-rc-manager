APP_NAME = Claude RC Manager
BUILD_DIR = .build/release
APP_DIR = $(BUILD_DIR)/$(APP_NAME).app

.PHONY: build test install uninstall clean

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

clean:
	rm -rf .build
