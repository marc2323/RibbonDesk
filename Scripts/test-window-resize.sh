#!/bin/zsh
set -eu
cd "${0:A:h}/.."
zsh Scripts/swift-local.sh build --product RibbonCoreChecks
bin_dir=$(zsh Scripts/swift-local.sh build --show-bin-path)
mkdir -p .build/window-resize-checks
xcrun swiftc -parse-as-library -swift-version 5 -module-name WindowResizeChecks \
    -module-cache-path "$PWD/.build/module-cache" -I "$bin_dir/Modules" \
    Sources/RibbonDesk/WindowResizeStaging.swift Tests/WindowResizeChecks/main.swift \
    "$bin_dir"/RibbonCore.build/*.swift.o \
    -o .build/window-resize-checks/WindowResizeChecks
.build/window-resize-checks/WindowResizeChecks
