# RibbonDesk development

Use `docs/DEVELOPMENT.md` for build and validation commands and the engine's
`PaneruEngine/AGENTS.md` for Rust changes.

## Build storage

- Cargo commands run from this repository or its subdirectories share
  `.build/paneru-engine` through `.cargo/config.toml`. Use that directory for
  builds, Clippy, tests, and the vendored transport tests; avoid task-specific
  target directories or an additional `PaneruEngine/target` cache.
- Development, test, and fast-release profiles keep filename/line information
  for backtraces and disable incremental compilation to limit cache size.
  Use a temporary command-line override if full debugger information is needed.
- Keep Swift module caches in the existing
  `.build/paneru-preferences/module-cache` when compatible with the check.
- Do not copy `.build`, dependency installations, or compiler caches into review
  snapshots. Preserve source changes, fixtures, vendored source, configuration,
  release packages, installed apps, and rollback builds. Remove only disposable
  generated data created by the current task when it is no longer in use.
