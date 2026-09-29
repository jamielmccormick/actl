# actl: engine (Bun, compiled) + the native macOS app (Swift package in app/).
# Outputs land in build/ (gitignored).

APP      := build/actl.app
CONTENTS := $(APP)/Contents
SWIFTBIN := app/.build/release
VERSION  ?= 0.1.0
BUILD    ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
MIN_OS   := 15.0

.PHONY: engine app install run test clean icon

engine:
	bun run build:engine

app: engine
	cd app && swift build -c release
	rm -rf $(APP)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(SWIFTBIN)/actl-app $(CONTENTS)/MacOS/actl
	cp -R $(SWIFTBIN)/actl_ActlApp.bundle $(CONTENTS)/Resources/
	cp -R $(SWIFTBIN)/actl_ActlFixtures.bundle $(CONTENTS)/Resources/
	cp build/actl $(CONTENTS)/Resources/actl
	cp design/glyphs/menubar-*.svg $(CONTENTS)/Resources/
	cp design/brand/actl-icon-attention-1024.png design/brand/actl-icon-error-1024.png $(CONTENTS)/Resources/
	$(MAKE) icon
	cp build/actl.icns $(CONTENTS)/Resources/actl.icns
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>CFBundleName</key><string>actl</string>' \
	  '  <key>CFBundleDisplayName</key><string>actl</string>' \
	  '  <key>CFBundleIdentifier</key><string>dev.actl.app</string>' \
	  '  <key>CFBundleExecutable</key><string>actl</string>' \
	  '  <key>CFBundleIconFile</key><string>actl</string>' \
	  '  <key>CFBundlePackageType</key><string>APPL</string>' \
	  '  <key>CFBundleShortVersionString</key><string>$(VERSION)</string>' \
	  '  <key>CFBundleVersion</key><string>$(BUILD)</string>' \
	  '  <key>LSMinimumSystemVersion</key><string>$(MIN_OS)</string>' \
	  '  <key>LSUIElement</key><true/>' \
	  '  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>' \
	  '  <key>NSHumanReadableCopyright</key><string>MIT © Jamie McCormick</string>' \
	  '  <key>NSSupportsAutomaticTermination</key><false/>' \
	  '  <key>NSHighResolutionCapable</key><true/>' \
	  '</dict></plist>' > $(CONTENTS)/Info.plist
	printf 'APPL????' > $(CONTENTS)/PkgInfo
	codesign --force --deep -s - $(APP)
	@echo "Built $(APP)"

# .icns from the PNG ladder (iconutil needs the iconset naming).
icon:
	rm -rf build/actl.iconset
	mkdir -p build/actl.iconset
	cp design/brand/actl-icon-16.png   build/actl.iconset/icon_16x16.png
	cp design/brand/actl-icon-32.png   build/actl.iconset/icon_16x16@2x.png
	cp design/brand/actl-icon-32.png   build/actl.iconset/icon_32x32.png
	cp design/brand/actl-icon-64.png   build/actl.iconset/icon_32x32@2x.png
	cp design/brand/actl-icon-128.png  build/actl.iconset/icon_128x128.png
	cp design/brand/actl-icon-256.png  build/actl.iconset/icon_128x128@2x.png
	cp design/brand/actl-icon-256.png  build/actl.iconset/icon_256x256.png
	cp design/brand/actl-icon-512.png  build/actl.iconset/icon_256x256@2x.png
	cp design/brand/actl-icon-512.png  build/actl.iconset/icon_512x512.png
	cp design/brand/actl-icon-1024.png build/actl.iconset/icon_512x512@2x.png
	iconutil -c icns build/actl.iconset -o build/actl.icns

install: app
	mkdir -p ~/Applications
	rm -rf ~/Applications/actl.app
	cp -R $(APP) ~/Applications/actl.app
	@echo "Installed ~/Applications/actl.app"

run: app
	open $(APP)

test:
	cd app && swift test

clean:
	rm -rf build/actl build/actl.app build/actl.icns build/actl.iconset app/.build
