DERIVED := build/DerivedData
APP_DEBUG := $(DERIVED)/Build/Products/Debug/Arbor.app

.PHONY: project build run test app icon clean

project:
	xcodegen generate

build: project
	xcodebuild -project Arbor.xcodeproj -scheme Arbor -configuration Debug -derivedDataPath $(DERIVED) build

run: build
	open $(APP_DEBUG)

test: project
	xcodebuild -project Arbor.xcodeproj -scheme Arbor -derivedDataPath $(DERIVED) test

app: project
	xcodebuild -project Arbor.xcodeproj -scheme Arbor -configuration Release -derivedDataPath $(DERIVED) build
	rm -rf build/Arbor.app && cp -R $(DERIVED)/Build/Products/Release/Arbor.app build/

icon:
	swift scripts/make-icon.swift Arbor/Resources/Assets.xcassets/AppIcon.appiconset

clean:
	rm -rf build Arbor.xcodeproj
