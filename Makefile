# First Apple Development identity in the keychain unless set explicitly. "-" signs ad hoc.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $$2; exit }')
BUNDLE_ID ?= com.appdin.notchline
VERSION ?= 0.1.0
BUILD_NUMBER ?= 1

# Extra flags for swift build, for example --disable-sandbox inside Homebrew.
SWIFT_FLAGS ?=

BUILD_DIR := build
APP := $(BUILD_DIR)/Notchline.app
ZIP := $(BUILD_DIR)/Notchline-$(VERSION).zip
BIN_DIR = $(shell swift build -c release $(SWIFT_FLAGS) --show-bin-path)
# A secure timestamp needs a real identity; ad hoc signatures go without.
CODESIGN_FLAGS = --force --options runtime $(if $(filter -,$(SIGN_IDENTITY)),,--timestamp)

.PHONY: all build test app release run fetch android android-test clean

all: app

build:
	swift build -c release $(SWIFT_FLAGS) --product Notchline

test:
	swift test

# Assemble and sign Notchline.app from the release binary.
app: build
	@test -n "$(SIGN_IDENTITY)" || { echo "No Apple Development signing identity found. Set SIGN_IDENTITY."; exit 1; }
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN_DIR)/Notchline $(APP)/Contents/MacOS/Notchline
	sed -e 's/$$(BUNDLE_ID)/$(BUNDLE_ID)/' \
	    -e 's/$$(VERSION)/$(VERSION)/' \
	    -e 's/$$(BUILD_NUMBER)/$(BUILD_NUMBER)/' \
	    Resources/Info.plist > $(APP)/Contents/Info.plist
	cp Sources/NotchlineCore/Resources/locations.json Sources/NotchlineCore/Resources/confidence.json $(APP)/Contents/Resources/
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	codesign $(CODESIGN_FLAGS) -s "$(SIGN_IDENTITY)" $(APP)
	codesign --verify --strict $(APP)

# Universal build zipped for GitHub Releases and the Homebrew cask. With NOTARIZE=1 the zip is
# notarized and the ticket stapled, which needs a Developer ID SIGN_IDENTITY and APPLE_ID,
# APPLE_TEAM_ID and APPLE_APP_PASSWORD (an app-specific password) in the environment.
release: SWIFT_FLAGS += --arch arm64 --arch x86_64
release: app
	rm -f $(ZIP)
	ditto -c -k --norsrc --noextattr --keepParent $(APP) $(ZIP)
ifeq ($(NOTARIZE),1)
	xcrun notarytool submit $(ZIP) --apple-id "$$APPLE_ID" --team-id "$$APPLE_TEAM_ID" --password "$$APPLE_APP_PASSWORD" --wait
	xcrun stapler staple $(APP)
	rm -f $(ZIP)
	ditto -c -k --norsrc --noextattr --keepParent $(APP) $(ZIP)
endif
	shasum -a 256 $(ZIP)

# Quit any running copy first. `open` would otherwise just activate it instead of launching the new build.
run: app
	-pkill -x Notchline
	@while pgrep -x Notchline > /dev/null; do sleep 0.2; done
	open $(APP)

# Live snapshot for one location: make fetch LOCATION=mt-baker
LOCATION ?= mt-baker
fetch:
	swift run notchline-fetch $(LOCATION)

# Android debug APK, and the core's tests on a connected device or emulator. See scripts/android.sh.
android:
	scripts/android.sh apk

android-test:
	scripts/android.sh test

clean:
	rm -rf $(BUILD_DIR) .build
