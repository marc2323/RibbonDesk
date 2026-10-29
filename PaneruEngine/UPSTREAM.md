# Upstream source

Paneru 0.5.2, tag `v0.5.2`, commit `b1b6abbd3f1a4be138152b6f0389c9ff1b27a269`.
Source: https://github.com/karinushka/paneru
License: MIT; see LICENSE.txt.

## Local changes

- The local distribution is named RibbonDesk in macOS metadata, setup dialogs,
  and menu-bar controls. The engine CLI, IPC identifiers, storage paths, original
  copyright, and upstream attribution remain compatible with Paneru.
- `disabled_spaces` excludes native macOS desktops from window discovery,
  including background window creation. The input tap passes all input through
  immediately on an excluded desktop. The companion stops the engine there and
  resumes on enabled desktops. Its click-protection tap follows the same policy.
- The Lua startup configuration and input tap now share a config handle, so
  native input sees desktop exclusions and subsequent configuration reloads.
- `preserve_scroll_until_click` adds a per-workspace `ScrollPositionHold` component
  when a gesture or modifier scroll moves the strip. It defaults off upstream and
  is enabled by our Lua configuration.
- While held, focus-driven reshuffle, ensure-visible, auto-centering, magnetic
  snap forces, and resize-based viewport nudges cannot change the strip offset.
- Ordinary clicks interact with partially visible windows without releasing the
  hold. Command-click on a managed window releases only its workspace's hold on
  mouse-up and brings the window into view, regardless of `window_hidden_ratio`.
  Either Command key works; releasing Command before mouse-up still completes it.
  Hover, activation, external focus, and clicks outside managed windows retain it.
- Explicit focus navigation releases the target workspace's hold and inertia,
  then reveals the window even if it already had focus or the hidden ratio is 1.
- Command-click reveals use a short ease-out animation independent of general
  animation speed. New manual scrolling cancels it and restores the hold.
- Shortcuts and mouse clicks accept group-only modifier flags from remote or
  accessibility input, while retaining physical left/right modifier distinctions.
- Natural scrolling and inertia retain their existing integrator and boundaries.
- `AXEnhancedUserInterface` is re-checked at most once a second per app instead
  of being cached as absent for the app's lifetime, and stays off until the
  app's windows have been still for 400 ms rather than toggling around every
  move. Apps with it enabled animate AX moves, which turned infinite-ribbon
  lap changes into full-screen sweeps.
- Window move notifications are dropped while the active strip is scrolling,
  since every frame then assigns positions directly.
- Harness regressions check actual scroll movement, repeated/external focus,
  hover, activation, ordinary clicks, and Command-click reveal in both focus modes.
- Three upstream test durations use seconds instead of 1000 milliseconds for the
  pinned compiler's Clippy rules. The default border-radius assertion now matches
  the existing resolver, which returns `Value(10.0)` for `Auto`.

The installed Homebrew binary is retained as a fallback; the companion runs its
bundled local build. Rust 1.95.0 is pinned for reproducible builds.
