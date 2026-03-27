.DEFAULT_GOAL := package

PROJECT := SimpleAUHost.xcodeproj
SCHEME := SimpleAUHost
APP_NAME := SimpleAUHost
CONFIGURATION ?= Release
DESTINATION ?= platform=macOS
DERIVED_DATA := $(CURDIR)/build/DerivedData
DIST_DIR := $(CURDIR)/dist
APP_BUNDLE := $(APP_NAME).app
BUILT_APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_BUNDLE)
STAGED_APP := $(DIST_DIR)/$(APP_BUNDLE)
PACKAGE := $(DIST_DIR)/$(APP_NAME)-$(CONFIGURATION).zip
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: help build bundle package run clean

help:
	@printf "Targets:\n"
	@printf "  make build    Build %s in %s\n" "$(APP_BUNDLE)" "$(DERIVED_DATA)"
	@printf "  make bundle   Copy the built app bundle into %s\n" "$(DIST_DIR)"
	@printf "  make package  Zip the app bundle for transfer to another Mac\n"
	@printf "  make run      Launch the built app\n"
	@printf "  make clean    Remove build and dist artifacts\n"

build:
	@mkdir -p "$(DERIVED_DATA)" "$(DIST_DIR)"
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		-destination "$(DESTINATION)" \
		build

bundle: build
	@rm -rf "$(STAGED_APP)"
	ditto "$(BUILT_APP)" "$(STAGED_APP)"

package: bundle
	@rm -f "$(PACKAGE)"
	ditto -c -k --sequesterRsrc --keepParent "$(STAGED_APP)" "$(PACKAGE)"
	@printf "Created %s\n" "$(PACKAGE)"

run: build
	@pkill -x "$(APP_NAME)" >/dev/null 2>&1 || true
	@touch "$(BUILT_APP)" "$(BUILT_APP)/Contents/Info.plist"
	@"$(LSREGISTER)" -f "$(BUILT_APP)" >/dev/null 2>&1 || true
	open -n "$(BUILT_APP)"

clean:
	rm -rf "$(CURDIR)/build" "$(DIST_DIR)"
