use bevy::prelude::*;
use std::time::Duration;

use super::TestHarness;
use crate::commands::Command;
use crate::config::{Config, MainOptions, WindowParams};
use crate::ecs::decorations::{OverlayMotion, OverlayState};
use crate::ecs::{ActiveWorkspaceMarker, FocusedMarker, Scrolling, systems};
use crate::events::Event;
use crate::manager::Window;

#[derive(Resource, Default)]
struct OutlineSamples {
    enabled: bool,
    swiping: usize,
    inertia: usize,
    resting: usize,
    settling: usize,
    positions: Vec<f64>,
    changes: usize,
}

fn observe_outline(
    mut samples: ResMut<OutlineSamples>,
    overlay: Res<OverlayState>,
    focused: Query<&Window, With<FocusedMarker>>,
    active: Query<Option<&Scrolling>, With<ActiveWorkspaceMarker>>,
    motion: Res<OverlayMotion>,
) {
    if !samples.enabled {
        return;
    }
    samples.changes += usize::from(overlay.is_changed());
    match active.single().expect("active workspace") {
        Some(scroll) if scroll.is_user_swiping => samples.swiping += 1,
        Some(_) => samples.inertia += 1,
        None if motion.is_settling() => samples.settling += 1,
        None => samples.resting += 1,
    }
    if motion.is_settling() {
        assert_eq!(*overlay, OverlayState::Hidden);
        return;
    }
    let window = focused.single().expect("focused window");
    let OverlayState::Visible { frame, border, .. } = &*overlay else {
        panic!("outline must return at the settled position: {overlay:?}");
    };
    assert!(border.is_some());
    let actual = window.frame();
    assert!(
        (frame.origin.x - f64::from(actual.min.x + window.horizontal_padding())).abs()
            < f64::EPSILON
    );
    assert!(
        (frame.size.width - f64::from(actual.width() - 2 * window.horizontal_padding())).abs()
            < f64::EPSILON
    );
    samples.positions.push(frame.origin.x);
}

#[test]
fn outline_hides_through_gestures_inertia_and_settling() {
    let config: Config = (
        MainOptions {
            border_active_window: Some(true),
            focus_follows_mouse: Some(false),
            preserve_scroll_until_click: Some(true),
            swipe_gesture_fingers: Some(3),
            ..Default::default()
        },
        vec![],
    )
        .into();
    let mut harness = TestHarness::new().with_config(config).with_windows(4);
    harness
        .app
        .init_resource::<OutlineSamples>()
        .add_systems(PostUpdate, observe_outline.after(systems::render_overlays));
    harness = harness.on_iteration(0, |world, _| {
        world.resource_mut::<OutlineSamples>().enabled = true;
    });
    harness.run(vec![
        Event::MenuOpened { window_id: 0 },
        Event::WindowFocused { window_id: 1 },
        Event::Swipe {
            delta: 0.04,
            fingers: 3,
        },
        Event::Swipe {
            delta: 0.04,
            fingers: 3,
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
        // Modifier-wheel input uses the same adjustable release momentum.
        Event::Scroll { delta: 0.2 },
        Event::Scroll { delta: -0.1 },
    ]);
    harness.advance(Duration::from_secs(2));
    let samples = harness.world().resource::<OutlineSamples>();
    assert!(samples.swiping > 0, "must cover fingers driving the strip");
    assert!(samples.inertia > 0, "must cover momentum after finger lift");
    assert!(samples.resting > 0, "must cover the settled strip");
    assert!(
        samples.settling > 0,
        "must cover the quiet period after motion"
    );
    assert!(
        samples
            .positions
            .windows(2)
            .any(|pair| (pair[0] - pair[1]).abs() > 0.5),
        "test must actually move the focused window"
    );
    let changes = samples.changes;
    harness.advance(std::time::Duration::from_secs(2));
    assert_eq!(
        harness.world().resource::<OutlineSamples>().changes,
        changes,
        "resting windows must not request additional native overlay updates"
    );
}

#[test]
fn continuous_modifier_scroll_only_hides_once_and_draws_once_after_settling() {
    let config: Config = (
        MainOptions {
            border_active_window: Some(true),
            focus_follows_mouse: Some(false),
            preserve_scroll_until_click: Some(true),
            ..Default::default()
        },
        vec![],
    )
        .into();
    let mut harness = TestHarness::new().with_config(config).with_windows(4);
    harness
        .app
        .init_resource::<OutlineSamples>()
        .add_systems(PostUpdate, observe_outline.after(systems::render_overlays));
    harness.run(vec![Event::MenuOpened { window_id: 0 }]);
    harness.world().resource_mut::<OutlineSamples>().enabled = true;
    for step in 0..80 {
        harness.world().write_message(Event::Scroll {
            delta: if step % 2 == 0 { 0.2 } else { -0.15 },
        });
        harness.advance(Duration::from_millis(20));
        assert_eq!(
            *harness.world().resource::<OverlayState>(),
            OverlayState::Hidden
        );
    }
    assert_eq!(harness.world().resource::<OutlineSamples>().changes, 1);
    harness.advance(Duration::from_millis(100));
    assert_eq!(
        *harness.world().resource::<OverlayState>(),
        OverlayState::Hidden
    );
    // Allow the release coast and the outline quiet period to finish.
    harness.advance(Duration::from_secs(2));
    assert!(matches!(
        *harness.world().resource::<OverlayState>(),
        OverlayState::Visible { .. }
    ));
    assert_eq!(harness.world().resource::<OutlineSamples>().changes, 2);
}

#[test]
fn native_drag_and_resize_debounce_and_use_the_latest_color_when_settled() {
    let mut rule = WindowParams::new("^Window 0$", None);
    rule.floating = Some(true);
    let options = MainOptions {
        border_active_window: Some(true),
        focus_follows_mouse: Some(false),
        ..Default::default()
    };
    let config: Config = (options.clone(), vec![rule.clone()]).into();
    let mut harness = TestHarness::new().with_config(config).with_windows(2);
    harness
        .app
        .init_resource::<OutlineSamples>()
        .add_systems(PostUpdate, observe_outline.after(systems::render_overlays));
    harness.run(vec![
        Event::MenuOpened { window_id: 0 },
        Event::WindowFocused { window_id: 0 },
    ]);
    harness.world().resource_mut::<OutlineSamples>().enabled = true;
    for step in 0..20 {
        harness.mock_state.update_window(0, |window| {
            window.frame = IRect::new(100 + step * 8, 90, 600 + step * 9, 700);
        });
        harness
            .world()
            .write_message(Event::WindowMoved { window_id: 0 });
        harness
            .world()
            .write_message(Event::WindowResized { window_id: 0 });
        harness.advance(Duration::from_millis(40));
        assert_eq!(
            *harness.world().resource::<OverlayState>(),
            OverlayState::Hidden
        );
    }
    assert_eq!(harness.world().resource::<OutlineSamples>().changes, 1);
    let changed: Config = (
        MainOptions {
            border_color: Some("#FF0000".into()),
            ..options.clone()
        },
        vec![rule.clone()],
    )
        .into();
    harness.world().insert_resource(changed);
    harness.advance(Duration::from_millis(80));
    assert_eq!(
        *harness.world().resource::<OverlayState>(),
        OverlayState::Hidden
    );
    harness.advance(Duration::from_millis(200));
    let OverlayState::Visible {
        frame,
        border: Some(border),
        ..
    } = harness.world().resource::<OverlayState>()
    else {
        panic!("outline must return after the last native move");
    };
    assert!((frame.origin.x - 252.0).abs() < f64::EPSILON);
    assert_eq!(border.color, (1.0, 0.0, 0.0));
    assert_eq!(harness.world().resource::<OutlineSamples>().changes, 2);

    // Turning the feature off during the quiet period must cancel its return.
    harness.world().resource_mut::<OutlineSamples>().enabled = false;
    harness
        .mock_state
        .update_window(0, |window| window.frame.min.x += 10);
    harness
        .world()
        .write_message(Event::WindowMoved { window_id: 0 });
    harness.advance(Duration::from_millis(20));
    let disabled: Config = (
        MainOptions {
            border_active_window: Some(false),
            ..options
        },
        vec![rule],
    )
        .into();
    harness.world().insert_resource(disabled);
    harness.advance(Duration::from_millis(400));
    assert_eq!(
        *harness.world().resource::<OverlayState>(),
        OverlayState::Disabled
    );
}

#[test]
fn outline_still_hides_for_mission_control_and_returns_afterwards() {
    let config: Config = (
        MainOptions {
            border_active_window: Some(true),
            ..Default::default()
        },
        vec![],
    )
        .into();
    TestHarness::new()
        .with_config(config)
        .with_windows(2)
        .on_iteration(0, |world, _| {
            assert!(matches!(
                *world.resource::<OverlayState>(),
                OverlayState::Visible { .. }
            ));
        })
        .on_iteration(1, |world, _| {
            assert_eq!(*world.resource::<OverlayState>(), OverlayState::Hidden);
        })
        .on_iteration(2, |world, _| {
            assert!(matches!(
                *world.resource::<OverlayState>(),
                OverlayState::Visible { .. }
            ));
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            Event::MissionControlShowAllWindows,
            Event::MissionControlExit,
        ]);
}

#[test]
fn outline_refreshes_fullscreen_status_on_resize_notification() {
    let config: Config = (
        MainOptions {
            border_active_window: Some(true),
            ..Default::default()
        },
        vec![],
    )
        .into();
    TestHarness::new()
        .with_config(config)
        .with_windows(2)
        .on_iteration(0, |world, state| {
            assert!(matches!(
                *world.resource::<OverlayState>(),
                OverlayState::Visible { .. }
            ));
            // Leave geometry unchanged: the notification itself must invalidate
            // the native status, including transitions before the size updates.
            state.update_window(0, |window| window.is_full_screen = true);
        })
        .on_iteration(1, |world, state| {
            assert_eq!(*world.resource::<OverlayState>(), OverlayState::Hidden);
            state.update_window(0, |window| window.is_full_screen = false);
        })
        .on_iteration(2, |world, _| {
            assert!(matches!(
                *world.resource::<OverlayState>(),
                OverlayState::Visible { .. }
            ));
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            Event::WindowResized { window_id: 0 },
            Event::WindowResized { window_id: 0 },
        ]);
}

#[test]
fn floating_outline_checks_workspace_membership_after_space_events() {
    let mut rule = WindowParams::new("^Window 0$", None);
    rule.floating = Some(true);
    let config: Config = (
        MainOptions {
            border_active_window: Some(true),
            focus_follows_mouse: Some(false),
            ..Default::default()
        },
        vec![rule],
    )
        .into();
    TestHarness::new()
        .with_config(config)
        .with_windows(2)
        .on_iteration(1, |world, state| {
            assert!(matches!(
                *world.resource::<OverlayState>(),
                OverlayState::Visible { .. }
            ));
            state.update_window(0, |window| {
                window.workspace_id = super::TEST_WORKSPACE_ID + 100;
            });
        })
        .on_iteration(2, |world, state| {
            assert_eq!(*world.resource::<OverlayState>(), OverlayState::Hidden);
            state.update_window(0, |window| window.workspace_id = super::TEST_WORKSPACE_ID);
        })
        .on_iteration(3, |world, _| {
            assert!(matches!(
                *world.resource::<OverlayState>(),
                OverlayState::Visible { .. }
            ));
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            Event::WindowFocused { window_id: 0 },
            Event::SpaceChanged,
            Event::SpaceChanged,
        ]);
}
