APP_NAME = Claude RC Manager
BUILD_DIR = .build/release
APP_DIR = $(BUILD_DIR)/$(APP_NAME).app

.PHONY: build test app install clean

build:
	swift build -c release

test:
	swift test

app: build
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	cp "$(BUILD_DIR)/ClaudeRCManager" "$(APP_DIR)/Contents/MacOS/ClaudeRCManager"
	codesign --force --sign - "$(APP_DIR)"
	@echo "Built: $(APP_DIR)"

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_DIR)" "/Applications/$(APP_NAME).app"
	@echo "Installed to /Applications/$(APP_NAME).app"

clean:
	rm -rf .build
