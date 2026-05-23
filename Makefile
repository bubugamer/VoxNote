APP_NAME := VoxNote
BUNDLE_ID := com.VoxNote.app
CONFIG := release
BUILD_DIR := .build/$(CONFIG)
EXECUTABLE := $(BUILD_DIR)/$(APP_NAME)
INSTALL_DIR := $(HOME)/Applications
APP_DIR := $(INSTALL_DIR)/$(APP_NAME).app
CONTENTS_DIR := $(APP_DIR)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
RESOURCES_DIR := $(CONTENTS_DIR)/Resources
BUNDLED_MODELS_DIR := Resources/BundledModels

.PHONY: build run install clean clean-models bundle icon bundle-models offline-build

build: bundle

bundle: icon
	swift build -c $(CONFIG)
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(APP_DIR)"
	mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)"
	cp "$(EXECUTABLE)" "$(MACOS_DIR)/$(APP_NAME)"
	cp Resources/Info.plist "$(CONTENTS_DIR)/Info.plist"
	cp Resources/VoxNote.icns "$(RESOURCES_DIR)/VoxNote.icns"
	@if [ -d "$(BUNDLED_MODELS_DIR)" ]; then \
		cp -R "$(BUNDLED_MODELS_DIR)" "$(RESOURCES_DIR)/BundledModels"; \
	fi
	codesign --force --sign - \
		--entitlements Resources/VoxNote.entitlements \
		--identifier $(BUNDLE_ID) \
		"$(APP_DIR)"

offline-build: bundle-models bundle

bundle-models:
	swift run -c release ModelBundler --output "$(BUNDLED_MODELS_DIR)"

icon:
	@if [ ! -f Resources/VoxNote.icns ]; then \
		python3 Resources/generate_icon.py; \
	fi

run: build
	open "$(APP_DIR)"

install: build
	@echo "✓ Installed. Run with:  open \"$(INSTALL_DIR)/$(APP_NAME).app\""
	@echo "  Only one app bundle is kept: $(INSTALL_DIR)/$(APP_NAME).app"

clean:
	rm -rf .build dist Resources/VoxNote.iconset Resources/VoxNote.icns

clean-models:
	rm -rf "$(BUNDLED_MODELS_DIR)"
