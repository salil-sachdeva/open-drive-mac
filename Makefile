BUILD_DIR ?= /tmp/open-drive-build
SWIFTPM_BUILD_SYSTEM ?= native
SWIFTPM_ENV = CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swiftpm-module-cache
SWIFTPM_FLAGS = --build-system $(SWIFTPM_BUILD_SYSTEM) --disable-sandbox --scratch-path "$(BUILD_DIR)" -Xswiftc -module-cache-path -Xswiftc /tmp/swift-module-cache

.PHONY: help build test icon app dmg clean format

help:
	@echo "Open Drive for macOS — Build Targets:"
	@echo "  make build   Compile all Swift targets (OpenDriveCore, OpenDriveFS, OpenDriveApp)"
	@echo "  make test    Run the OpenDriveCoreTests unit & integration test suite"
	@echo "  make icon    Compile Icon/AppIcon.icon into Resources/Assets.car and AppIcon.icns"
	@echo "  make app     Assemble and code-sign 'dist/Open Drive.app' (+ OpenDriveFS.appex)"
	@echo "  make dmg     Package 'dist/OpenDrive.dmg'"
	@echo "  make clean   Remove build artifacts and dist directory"

build:
	$(SWIFTPM_ENV) swift build $(SWIFTPM_FLAGS)

test:
	$(SWIFTPM_ENV) swift test $(SWIFTPM_FLAGS)

icon:
	./tools/make_icon.sh

app:
	./Scripts/bundle-app.sh

dmg:
	./Scripts/create-dmg.sh

clean:
	rm -rf "$(BUILD_DIR)" dist
