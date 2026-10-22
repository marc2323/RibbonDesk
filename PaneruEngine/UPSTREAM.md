# Upstream source

Paneru 0.5.2, tag `v0.5.2`, commit `b1b6abbd3f1a4be138152b6f0389c9ff1b27a269`.
Source: https://github.com/karinushka/paneru
License: MIT; see LICENSE.txt.

## Local changes

- `preserve_scroll_until_click` adds a per-workspace `ScrollPositionHold` component
  when a gesture or modifier scroll moves the strip. It defaults off upstream and
  is enabled by our Lua configuration.
- While held, focus-driven reshuffle, ensure-visible, auto-centering, magnetic
  snap forces, and resize-based viewport nudges cannot change the strip offset.
- A mouse-down on a managed window releases only its workspace's hold. Hover,
  activation, keyboard focus, and clicks outside managed windows do not release it.
- Natural scrolling and inertia retain their existing integrator and boundaries.
- A harness regression checks actual scroll movement, repeated/external focus,
  hover, activation, a click outside windows, and release/reveal on a window click.
- Three upstream test durations use seconds instead of 1000 milliseconds for the
  pinned compiler's Clippy rules. The default border-radius assertion now matches
  the existing resolver, which returns `Value(10.0)` for `Auto`.

The installed Homebrew binary is retained as a fallback; the companion runs its
bundled local build. Rust 1.95.0 is pinned for reproducible builds. All 360 tests,
strict Clippy across all targets, and formatting checks pass.
