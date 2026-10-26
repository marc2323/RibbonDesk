use serde::Deserialize;

use crate::{config::deserialize_modifier, platform::Modifiers};

#[derive(Clone, Debug, Deserialize)]
#[cfg_attr(test, derive(serde::Serialize))]
pub enum SwipeGestureDirection {
    Natural,
    Reversed,
}

#[derive(Deserialize, Clone, Debug, Default)]
#[cfg_attr(test, derive(serde::Serialize))]
pub struct SwipeOptions {
    /// Swipe sensitivity multiplier. Lower values = less distance per finger
    /// movement. Range: 0.1–2.0. Default: 0.35.
    pub sensitivity: Option<f64>,

    /// Swipe inertia deceleration rate. Higher values = faster stop.
    /// Range: 1.0–100.0. Default: 4.0.
    pub deceleration: Option<f64>,

    /// Coast duration multiplier. Zero stops at finger lift. Default: 1.0.
    pub momentum: Option<f64>,

    /// Minimum release speed in viewport widths/second for full-width snapping.
    /// Zero disables flick snapping. Default: 0 (opt-in).
    pub snap_speed: Option<f64>,

    /// Fraction of a full-width column the projected coast must reveal.
    /// Default: 0.55. Range: 0.25–0.95.
    pub snap_visible: Option<f64>,

    /// Snap spring speed multiplier, independent of the flick threshold.
    /// Default: 1.0. Range: 0.2–4.0.
    pub snap_animation: Option<f64>,
    /// Which column sizes may snap. Half-width columns can align to either edge.
    pub snap_full_width: Option<bool>,
    pub snap_half_width: Option<bool>,
    /// Allow a snap to undo swipe progress. Default: false.
    pub snap_back: Option<bool>,
    /// Projected distance needed to leave an aligned column when `snap_back` is on.
    /// Fraction of the viewport. Default: 0.12. Range: 0–0.5.
    pub snap_exit_distance: Option<f64>,

    /// Local edge magnets replace flick snapping and the one-page gesture cap.
    /// Default: false (experimental, opt-in).
    pub magnetic_snapping: Option<bool>,
    /// Maximum speed an edge magnet can catch, in viewport widths/second.
    /// Default: 1.8. Range: 0.2–6.0.
    pub magnet_strength: Option<f64>,
    /// Attraction radius as a fraction of the viewport. Default: 0.2.
    /// Range: 0.03–0.4. All column widths have magnets at both edges.
    pub magnet_range: Option<f64>,

    /// Every horizontal three-finger gesture advances one full/half-width snap.
    /// Overrides free-scroll tuning unless magnetic snapping is on. Default: false.
    pub three_finger_paging: Option<bool>,

    /// Join the ribbon ends for horizontal scrolling and paging. Default: false.
    pub infinite_ribbon: Option<bool>,

    /// Three-finger upward swipe opens the native companion overview.
    pub ribbon_overview: Option<bool>,

    /// Swiping keeps sliding windows until the first or last window.
    /// Set to false to clamp so edge windows stay on-screen. Default: true.
    #[allow(dead_code)]
    pub continuous: Option<bool>,

    pub gesture: Option<GestureOptions>,
    pub scroll: Option<ScrollOptions>,
}

#[derive(Deserialize, Clone, Debug, Default)]
#[cfg_attr(test, derive(serde::Serialize))]
pub struct GestureOptions {
    /// The number of fingers required for swipe gestures to move windows.
    pub fingers_count: Option<usize>,

    /// Which direction swipe gestures should move windows.
    pub direction: Option<SwipeGestureDirection>,

    /// Whether to intercept vertical swipes.
    pub vertical: Option<bool>,
}

#[derive(Deserialize, Clone, Debug, Default)]
#[cfg_attr(test, derive(serde::Serialize))]
pub struct ScrollOptions {
    /// Select one adjacent window per wheel input. Default: false.
    pub window_step: Option<bool>,

    /// Modifier key(s) required for scroll wheel swiping.
    /// Accepts the same format as keybindings: "alt", "cmd", "alt + cmd", "alt + rcmd" etc.
    #[serde(default, deserialize_with = "deserialize_modifier")]
    #[cfg_attr(test, serde(serialize_with = "crate::config::serialize_modifier"))]
    pub modifier: Option<Modifiers>,

    /// Additional modifier key(s) that, combined with the scroll modifier,
    /// switches virtual workspaces vertically instead of scrolling horizontally.
    #[serde(default, deserialize_with = "deserialize_modifier")]
    #[cfg_attr(test, serde(serialize_with = "crate::config::serialize_modifier"))]
    pub vertical_modifier: Option<Modifiers>,
}
