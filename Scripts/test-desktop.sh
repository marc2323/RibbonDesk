#!/bin/zsh
set -eu
cd "${0:A:h}/.."
zsh Scripts/swift-local.sh build --product RibbonCoreChecks
zsh Scripts/swift-local.sh build --target SpaceInterop
bin_dir=$(zsh Scripts/swift-local.sh build --show-bin-path)
mkdir -p .build/desktop-checks
# Compile the actual view/controller sources with the runner, without the app
# entrypoint. CLT-only setup: no XCTest, downloads, AX permission, or OS input.
xcrun swiftc -parse-as-library -swift-version 5 -module-name RibbonDesktopChecks \
    -module-cache-path "$PWD/.build/module-cache" -I "$bin_dir/Modules" -I "$bin_dir/SpaceInterop.build" \
    Sources/RibbonDesk/AccessibilityBridge.swift Sources/RibbonDesk/WindowResizeStaging.swift Sources/RibbonDesk/GlobalShortcuts.swift \
    Sources/RibbonDesk/DeskController.swift Sources/RibbonDesk/TrackpadScrollSurface.swift \
    Sources/RibbonDesk/GlobalScroll.swift Sources/RibbonDesk/DesktopActivity.swift Sources/RibbonDesk/MotionAppAnimations.swift Sources/RibbonDesk/MotionBatchTransport.swift Sources/RibbonDesk/FrameClock.swift Sources/RibbonDesk/RuntimeDiagnostics.swift Sources/RibbonDesk/SessionStore.swift Sources/RibbonDesk/Spaces.swift \
    Tests/RibbonDesktopChecks/main.swift "$bin_dir"/RibbonCore.build/*.swift.o "$bin_dir"/SpaceInterop.build/*.o \
    -o .build/desktop-checks/RibbonDesktopChecks
.build/desktop-checks/RibbonDesktopChecks
