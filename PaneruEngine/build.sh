#!/bin/zsh
set -euo pipefail
project="${0:A:h}"
export CARGO_TARGET_DIR="${project:h}/.build/paneru-engine"
if ! command -v cargo >/dev/null; then
    toolchain=$(/opt/homebrew/opt/rustup/bin/rustup which --toolchain 1.95.0 cargo)
    export PATH="${toolchain:h}:$PATH"
fi
cargo build --manifest-path "$project/Cargo.toml" --locked --profile fast-release --bin paneru
