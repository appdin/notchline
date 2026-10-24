# First Apple Development identity in the keychain unless set explicitly.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $$2; exit }')
BUNDLE_ID ?= com.appdin.notchline
VERSION ?= 0.1.0
BUILD_NUMBER ?= 1

BUILD_DIR := build
APP := $(BUILD_DIR)/Notchline.app
BIN_DIR = $(shell swift build -c release --show-bin-path)

.PHONY: all build test app run fetch clean

all: app

build:
	swift build -c release --product Notchline

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
	cp Sources/NotchlineCore/Resources/locations.json $(APP)/Contents/Resources/
	codesign --force --options runtime --timestamp -s "$(SIGN_IDENTITY)" $(APP)
	codesign --verify --strict $(APP)

# Quit any running copy first. `open` would otherwise just activate it instead of launching the new build.
run: app
	-pkill -x Notchline
	@while pgrep -x Notchline > /dev/null; do sleep 0.2; done
	open $(APP)

# Live snapshot for one location: make fetch LOCATION=mt-baker
LOCATION ?= mt-baker
fetch:
	swift run notchline-fetch $(LOCATION)

clean:
	rm -rf $(BUILD_DIR) .build
