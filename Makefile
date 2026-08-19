APP_NAME = Claude RC Manager
BUILD_DIR = .build/release
APP_DIR = $(BUILD_DIR)/$(APP_NAME).app

.PHONY: build test app install uninstall clean

build:
	swift build -c release

test:
	swift test

app: build
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

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_DIR)" "/Applications/$(APP_NAME).app"
	@echo "Installed to /Applications/$(APP_NAME).app"

uninstall:
	@pgrep -x ClaudeRCManager >/dev/null && echo "Quit the app first (it stops its servers on quit)." && exit 1 || true
	rm -rf "/Applications/$(APP_NAME).app"
	@echo "Removed /Applications/$(APP_NAME).app"
	@echo "Kept: ~/Library/Application Support/$(APP_NAME)/ (config)"
	@echo "Kept: ~/Library/Logs/ClaudeRCManager/ (logs)"
	@echo "Delete those two folders to remove all data. If Start at Login"
	@echo "was enabled, macOS drops the login item with the app."

clean:
	rm -rf .build
