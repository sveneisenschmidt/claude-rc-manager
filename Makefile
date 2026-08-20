APP_NAME = Claude RC Manager
BUILD_DIR = .build/release
APP_DIR = $(BUILD_DIR)/$(APP_NAME).app

# The Developer ID identity, if this Mac has one. Empty means the build falls
# back to an ad-hoc signature, which is what a contributor without an Apple
# Developer account gets. Override on the command line to force one identity.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -o 'Developer ID Application: [^"]*' | head -1)

# The notarytool credentials, stored once with:
#   xcrun notarytool store-credentials claude-rc-manager \
#     --key <AuthKey.p8> --key-id <key id> --issuer <issuer uuid>
NOTARY_PROFILE ?= claude-rc-manager

DIST_DIR = dist
DMG = $(DIST_DIR)/$(APP_NAME).dmg
STAGING = $(BUILD_DIR)/dmg-staging

.PHONY: build test install uninstall reinstall stop start clean verify-signature dmg

# Builds the binary, assembles the .app bundle with all localizations, and
# signs it: Developer ID when this Mac has the certificate, ad-hoc otherwise.
# The Developer ID path adds the hardened runtime and a secure timestamp,
# because notarization rejects a build without them.
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
	@if [ -n "$(SIGN_IDENTITY)" ]; then \
		echo "Signing with $(SIGN_IDENTITY)"; \
		codesign --force --options runtime --timestamp \
			--sign "$(SIGN_IDENTITY)" "$(APP_DIR)"; \
	else \
		echo "No Developer ID found, signing ad-hoc"; \
		codesign --force --sign - "$(APP_DIR)"; \
	fi
	@echo "Built: $(APP_DIR)"

# Checks the signature of the built bundle. The seal is verified on every Mac;
# the Developer ID and hardened-runtime checks run only where a certificate
# exists, so this target passes on a contributor's ad-hoc build. It does not
# check notarization: a local build has no ticket, and `spctl` rejects every
# unnotarized bundle. The release workflow checks that after stapling.
verify-signature:
	codesign --verify --deep --strict --verbose=2 "$(APP_DIR)"
	@if [ -n "$(SIGN_IDENTITY)" ]; then \
		codesign -dvv "$(APP_DIR)" 2>&1 | grep -q "Authority=Developer ID Application" \
			|| { echo "not signed with Developer ID"; exit 1; }; \
		codesign -dvv "$(APP_DIR)" 2>&1 | grep -q "flags=.*runtime" \
			|| { echo "hardened runtime missing, notarization would reject it"; exit 1; }; \
		echo "Developer ID signature with hardened runtime: OK"; \
	else \
		echo "No Developer ID on this Mac, ad-hoc signature checks only."; \
	fi

# Builds the release DMG into dist/, overwriting the previous one. The app is
# notarized and stapled before it goes into the image, so it launches offline
# after the user drags it to /Applications; the image is notarized and stapled
# after that, so Gatekeeper passes on the downloaded file without a network
# check. Both rounds are needed: a ticket on the image does not travel with the
# app copied out of it. Release step, run by the maintainer.
dmg: build
	@test -n "$(SIGN_IDENTITY)" \
		|| { echo "No Developer ID on this Mac. A DMG must not ship ad-hoc signed."; exit 1; }
	@xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1 \
		|| { echo "No notarytool profile \"$(NOTARY_PROFILE)\". See the comment above the dmg target."; exit 1; }
	rm -rf "$(STAGING)" "$(DMG)"
	ditto -c -k --keepParent "$(APP_DIR)" "$(BUILD_DIR)/app.zip"
	xcrun notarytool submit "$(BUILD_DIR)/app.zip" \
		--keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(APP_DIR)"
	mkdir -p "$(STAGING)" "$(DIST_DIR)"
	cp -R "$(APP_DIR)" "$(STAGING)/"
	ln -s /Applications "$(STAGING)/Applications"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(STAGING)" \
		-ov -format UDZO "$(DMG)"
	codesign --force --timestamp --sign "$(SIGN_IDENTITY)" "$(DMG)"
	xcrun notarytool submit "$(DMG)" \
		--keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG)"
	spctl --assess --type open --context context:primary-signature -v "$(DMG)"
	@echo "Built: $(DMG)"

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
