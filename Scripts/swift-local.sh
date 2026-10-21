#!/bin/zsh
set -eu
cd "${0:A:h}/.."
# Keep compiler and SwiftPM writes inside this project in restricted workspaces.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
mkdir -p .build/module-cache .build/cache .build/configuration .build/security
swift "$@" --disable-sandbox --scratch-path .build --cache-path .build/cache \
    --config-path .build/configuration --security-path .build/security --manifest-cache local
