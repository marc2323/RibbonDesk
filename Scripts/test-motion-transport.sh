#!/bin/zsh
set -eu
cd "${0:A:h}/.."
mkdir -p .build/motion-transport-checks
xcrun swiftc -parse-as-library -swift-version 5 -module-name MotionTransportChecks \
    -module-cache-path "$PWD/.build/module-cache" \
    Sources/RibbonDesk/MotionAppAnimations.swift Sources/RibbonDesk/MotionBatchTransport.swift \
    Tests/MotionTransportChecks/main.swift \
    -o .build/motion-transport-checks/MotionTransportChecks
.build/motion-transport-checks/MotionTransportChecks
