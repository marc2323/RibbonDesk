# Paneru Settings

A scrolling ribbon of windows for macOS, with a native menu-bar app and an
overview for navigating and arranging your whole workspace.

[Download v1.16](https://github.com/marc2323/RibbonDesk/releases/tag/v1.16) ·
[Settings guide](PaneruPreferences/README.md) ·
[Build and development](docs/DEVELOPMENT.md)

## What it does

- **Scroll through your windows.** Move along the ribbon with three-finger
  gestures, choose one-window paging or free scrolling, and tune momentum and snapping.
- **See the bigger picture.** Ribbon Overview shows windows in order at one-third
  scale. Browse long ribbons, jump to a window, rearrange, close, or quit an app.
- **Adjust everything from the menu bar.** Settings save automatically, including
  activation mode, window gaps, the active-window outline, and saved feel presets.
- **Choose where it runs.** Enable window management separately for each macOS
  Desktop, pause it when needed, and optionally start it at login.

## Install

**Requirements:** Apple Silicon Mac, macOS 13 or later. The release download
includes the engine; Rust, Homebrew, and Xcode are not required.

1. Download **Paneru-Settings-1.16-macos-arm64.zip** from the
   [release page](https://github.com/marc2323/RibbonDesk/releases/tag/v1.16) and extract it.
2. If Paneru is running, choose **Quit** in its menu-bar settings first.
3. Open **Install.command** from the extracted folder. Keep the app, installer,
   and `paneru-init.lua` together. The installer backs up the previous app and
   configuration and preserves your preferences and feel presets.
4. Open `~/Applications/Paneru Settings.app`.
5. Complete the macOS **Accessibility** setup when requested. Allow **Screen
   Recording** for Paneru Settings to enable window previews in overview.

**Signing status:** v1.16 uses a local development signature and is **not
Apple-notarized**. macOS may require manual approval before opening a downloaded
copy. See [Apple’s guidance for opening apps](https://support.apple.com/en-us/102445).

To compile and install your own copy, see the [development guide](docs/DEVELOPMENT.md#build-from-source).

## Everyday use

Click the three-window menu-bar icon to open Settings, or press **Control–Option–S**.
Changes apply and save automatically. **Pause/Start**, **Restart**, **Overview**,
and **Quit** are under Window management.

Swipe horizontally with **three fingers** to move through the ribbon. By default,
each swipe advances one window alignment; turn off **Three-finger paging** for
free scrolling. Ordinary two-finger scrolling continues to scroll your apps.

Hovering and ordinary clicks keep the ribbon where you left it. **Command-click
a managed window** to bring it fully into view. Keyboard navigation also reveals
the selected window.

## Ribbon Overview

Swipe **up with three fingers**, press **Control–Option–O**, or click **Overview**
in Settings. Windows keep their ribbon order, proportions, gaps, and stacks.
The view starts near your current position and scrolls horizontally when the
ribbon is longer than the screen.

| Action | Control |
| --- | --- |
| Browse the ribbon | Two-finger scroll, mouse wheel, or the bottom scroll track |
| Select a preview | Hover or use the left/right arrow keys |
| Enter a window | Click its preview or press Return |
| Enter the window under your cursor | Three-finger swipe down |
| Move the selected window left/right | **J / K**, or **Control–Option–J / K** |
| Rearrange by dragging | Drop on either half of another preview |
| Close the selected window | **⌘W**, the Close Window button, or the context menu |
| Quit the selected window’s app | **⌘Q**, the Quit button, or the context menu |
| Cancel and return to the original viewport | **Escape** or click the background |

Stacks and native tab groups move together. Closing or quitting keeps overview
open as windows disappear; save confirmations are revealed when an app needs
your response. With the cursor over the background, swipe down enters the
selected preview.

Previews are snapshots. Normal interaction resumes when you enter a window.
Transitions are instant by default; enable **Overview animation** in Settings
for the optional zoom. Reduce Motion also disables that animation.

## Keyboard shortcuts

Hold **Control + Option** while using these keys:

| Key | Action |
| --- | --- |
| **H / L** or **← / →** | Previous / next window |
| **J / K** | Move a window left/right and follow it |
| **Home / End** | First / last window |
| **2** | Half width |
| **0 / F** | Full width |
| **R** | Toggle half / full width |
| **T** | Toggle floating |
| **O** | Open Ribbon Overview |
| **S** | Open Settings |
| **Q** | Pause window management |

## Settings and help

The [settings guide](PaneruPreferences/README.md) explains scrolling, snapping,
feel presets, appearance, Desktop exclusions, and launch at login.

- **Blank overview previews:** allow Screen Recording for Paneru Settings.
  Protected content can remain blank.
- **Gestures or hotkeys do nothing:** check that management is running and
  **This Desktop** is enabled in Settings.
- **The app cannot start or Click mode is unavailable:** check the macOS
  Accessibility permissions requested by the app and bundled engine.

Build instructions, test commands, runtime paths, and implementation notes are
in the [development guide](docs/DEVELOPMENT.md).

## About this repository

This app bundles [Paneru](https://github.com/karinushka/paneru) 0.5.2 with local
window-management changes. See the [upstream notes](PaneruEngine/UPSTREAM.md)
and [license notices](THIRD_PARTY_NOTICES.txt).

The repository keeps its RibbonDesk name for existing links. The retired
prototype is preserved under the `ribbondesk-prototype-retired` Git tag.
