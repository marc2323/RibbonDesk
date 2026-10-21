#!/bin/zsh
set -eu
cd "${0:A:h}/.."
zsh Scripts/swift-local.sh build --product RibbonCoreChecks
.build/debug/RibbonCoreChecks
