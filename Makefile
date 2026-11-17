APP_NAME := DontsTool
PROJECT := DontsTool.xcodeproj
SCHEME := DontsTool
CONFIG ?= Debug
DERIVED := build
APP := $(DERIVED)/Build/Products/$(CONFIG)/$(APP_NAME).app

.PHONY: project build app run test test-bridge test-updater editor test-editor release clean distclean

project:
	xcodegen generate --spec project.yml

build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) build

app: build
	@test -d "$(APP)" || (echo "未找到 $(APP)"; exit 1)
	@echo "构建完成: $(APP)"

run: app
	@pkill -x $(APP_NAME) 2>/dev/null || true
	open "$(APP)" --args $(ARGS)

test: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' \
		-derivedDataPath $(DERIVED) test

test-bridge: project
	xcodebuild -project $(PROJECT) -scheme DontsToolBridgeTests -destination 'platform=macOS' \
		-derivedDataPath $(DERIVED) test

test-updater: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) -resolvePackageDependencies
	python3 -m unittest discover -s scripts/tests -p 'test_update_feed.py'

editor:
	cd Web/NotesEditor && npm ci && npm run build

test-editor:
	cd Web/NotesEditor && npm ci && npm test && npm run build

release:
	DT_DERIVED_DATA="$(abspath $(DERIVED))" ./scripts/package-release.sh

clean:
	rm -rf $(DERIVED) dist

distclean: clean
	rm -rf $(PROJECT)
