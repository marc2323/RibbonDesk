use std::time::Duration;

use bevy::prelude::*;

use super::{TEST_DISPLAY_WIDTH, TestHarness};
use crate::commands::{Command, Direction, Operation};
use crate::config::Config;
use crate::ecs::layout::LayoutStrip;
use crate::ecs::{ActiveWorkspaceMarker, Position, ScrollPositionHold, Scrolling};
use crate::events::Event;
use crate::util::round_px;

fn harness(
    momentum: f64,
    snap_speed: f64,
    visible: f64,
    full_width: bool,
    reversed: bool,
) -> TestHarness {
    harness_with_tuning(
        momentum,
        snap_speed,
        visible,
        full_width.then_some(1.0),
        reversed,
        "",
    )
}

fn harness_with_tuning(
    momentum: f64,
    snap_speed: f64,
    visible: f64,
    width: Option<f64>,
    reversed: bool,
    tuning: &str,
) -> TestHarness {
    let width_rule = width.map_or_else(String::new, |width| {
        format!("[windows.default]\ntitle = \".*\"\nwidth = {width}\n")
    });
    let direction = if reversed { "Reversed" } else { "Natural" };
    let decay_rule = if tuning.contains("deceleration =") {
        ""
    } else {
        "deceleration = 4.0"
    };
    let sensitivity_rule = if tuning.contains("sensitivity =") {
        ""
    } else {
        "sensitivity = 1.0"
    };
    let config = Config::try_from(
        format!(
            r#"
[options]
auto_center = false
preserve_scroll_until_click = true
focus_follows_mouse = false
animation_speed = 10000.0
[swipe]
{sensitivity_rule}
{decay_rule}
momentum = {momentum}
snap_speed = {snap_speed}
snap_visible = {visible}
continuous = false
{tuning}
[swipe.gesture]
fingers_count = 3
direction = "{direction}"
{width_rule}
"#
        )
        .as_str(),
    )
    .expect("scroll test config");
    let mut h = TestHarness::new().with_config(config).with_windows(12);
    h.run(vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::First)),
        },
    ]);
    assert_eq!(offset(&mut h), 0);
    h
}

fn offset(h: &mut TestHarness) -> i32 {
    let world = h.world();
    world
        .query_filtered::<&Position, With<ActiveWorkspaceMarker>>()
        .single(world)
        .expect("active strip")
        .x
}

fn frame(h: &mut TestHarness, events: impl IntoIterator<Item = Event>) {
    for event in events {
        h.world().write_message(event);
    }
    h.advance(Duration::from_millis(20));
}

fn swipe(delta: f64) -> Event {
    Event::Swipe { delta, fingers: 3 }
}

fn settled(h: &mut TestHarness) -> i32 {
    h.advance(Duration::from_secs(6));
    let world = h.world();
    assert!(
        world.query::<&Scrolling>().iter(world).next().is_none(),
        "settled strips must stop scheduling frames"
    );
    assert!(
        world
            .query::<&ScrollPositionHold>()
            .iter(world)
            .next()
            .is_some(),
        "flicks retain manual scroll ownership"
    );
    offset(h)
}

#[test]
fn momentum_tracks_release_speed_and_slider_without_extra_motion_under_fingers() {
    let mut distances = Vec::new();
    for momentum in [0.0, 0.5, 1.5] {
        let mut h = harness(momentum, 0.0, 0.55, false, false);
        frame(&mut h, [Event::TouchpadDown, swipe(0.06)]);
        let dragged = offset(&mut h);
        assert_eq!(dragged, -61, "direct motion is independent of momentum");
        h.advance(Duration::from_millis(240));
        assert_eq!(
            offset(&mut h),
            dragged,
            "stationary fingers must never start a coast"
        );
        // Refresh the physical velocity, then release in the same input frame.
        frame(&mut h, [swipe(0.06)]);
        frame(&mut h, [swipe(0.06), Event::TouchpadUp]);
        distances.push(settled(&mut h));
    }
    assert_eq!(
        distances[0], -184,
        "zero momentum ends at the physical drag offset"
    );
    assert!(
        distances[2] < distances[1] && distances[1] < distances[0],
        "more momentum must coast farther: {distances:?}"
    );

    let mut fast = harness(1.0, 0.0, 0.55, false, false);
    frame(
        &mut fast,
        [Event::TouchpadDown, swipe(0.06), Event::TouchpadUp],
    );
    let fast_end = settled(&mut fast);
    let mut slow = harness(1.0, 0.0, 0.55, false, false);
    frame(&mut slow, [Event::TouchpadDown]);
    for _ in 0..6 {
        frame(&mut slow, [swipe(0.01)]);
    }
    frame(&mut slow, [Event::TouchpadUp]);
    assert!(
        fast_end < settled(&mut slow) - 300,
        "equal finger travel with a faster release must coast farther"
    );
}

#[test]
fn classic_flick_snaps_every_ribbon_width_even_with_legacy_size_filters_off() {
    for ratio in [0.2, 0.35, 0.65, 0.8, 1.3, 1.8] {
        for reversed in [false, true] {
            let mut h = harness_with_tuning(
                1.0,
                0.1,
                0.55,
                Some(ratio),
                reversed,
                "snap_full_width = false\nsnap_half_width = false",
            );
            let order = columns(&mut h);
            let delta = ratio * if reversed { -0.06 } else { 0.06 };
            frame(
                &mut h,
                [Event::TouchpadDown, swipe(delta), Event::TouchpadUp],
            );
            let world = h.world();
            let target = world
                .query::<&Scrolling>()
                .single(world)
                .expect("active snap")
                .snap_target
                .expect("custom width must be eligible");
            assert!(order.contains(&target.entity));
            assert!(settled(&mut h) < 0);
            let aligned = order.iter().any(|entity| {
                let x = window_x(&mut h, *entity);
                let world = h.world();
                let width = world
                    .get::<crate::ecs::Bounds>(*entity)
                    .expect("column bounds")
                    .x;
                x == 0 || x + width == TEST_DISPLAY_WIDTH
            });
            assert!(aligned, "width ratio {ratio} must align an edge");
            assert_eq!(columns(&mut h), order);
        }
    }
}

#[test]
fn classic_custom_width_flicks_can_align_both_edges_in_either_direction() {
    for reversed in [false, true] {
        let mut h = harness_with_tuning(1.0, 0.8, 0.55, Some(0.65), reversed, "");
        let sign = if reversed { -1.0 } else { 1.0 };
        let width = round_px(f64::from(TEST_DISPLAY_WIDTH) * 0.65);
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(0.04 * sign), Event::TouchpadUp],
        );
        assert_eq!(settled(&mut h), -width, "leading edge");
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(-0.022 * sign), Event::TouchpadUp],
        );
        assert_eq!(
            settled(&mut h),
            TEST_DISPLAY_WIDTH - 2 * width,
            "trailing edge"
        );
    }
}

#[test]
fn classic_custom_width_snaps_across_both_sides_of_the_infinite_seam() {
    for reversed in [false, true] {
        let mut h = harness_with_tuning(
            1.0,
            0.8,
            0.55,
            Some(0.65),
            reversed,
            "infinite_ribbon = true",
        );
        let order = columns(&mut h);
        h.run(vec![Event::Command {
            command: Command::Window(Operation::Focus(Direction::Last)),
        }]);
        let delta = if reversed { -0.04 } else { 0.04 };
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(delta), Event::TouchpadUp],
        );
        settled(&mut h);
        assert_eq!(window_x(&mut h, order[0]), 0);
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(-delta), Event::TouchpadUp],
        );
        settled(&mut h);
        assert_eq!(window_x(&mut h, order[11]), 0);
        assert_eq!(columns(&mut h), order);
    }
}

#[test]
fn classic_snapping_excludes_floating_windows_from_its_candidates() {
    let mut h = harness_with_tuning(1.0, 0.8, 0.55, Some(0.65), false, "");
    let floating = columns(&mut h)[0];
    h.run(vec![Event::Command {
        command: Command::Window(Operation::Manage),
    }]);
    let order = columns(&mut h);
    assert!(!order.contains(&floating));
    let before = h
        .world()
        .get::<crate::manager::Window>(floating)
        .expect("floating window")
        .frame();
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(0.04), Event::TouchpadUp],
    );
    let world = h.world();
    let target = world
        .query::<&Scrolling>()
        .single(world)
        .expect("active snap")
        .snap_target
        .expect("Ribbon target");
    assert!(order.contains(&target.entity));
    assert_ne!(target.entity, floating);
    settled(&mut h);
    assert_eq!(
        h.world()
            .get::<crate::manager::Window>(floating)
            .expect("floating window")
            .frame(),
        before
    );
}

#[test]
fn fast_flick_snaps_full_width_columns_in_either_direction_and_keeps_the_hold() {
    for reversed in [false, true] {
        let mut h = harness(1.0, 0.8, 0.55, true, reversed);
        let delta = if reversed { -0.06 } else { 0.06 };
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(delta), Event::TouchpadUp],
        );
        let during = offset(&mut h);
        assert!(
            during < -61 && during > -TEST_DISPLAY_WIDTH,
            "snap animates instead of teleporting"
        );
        assert_eq!(
            settled(&mut h),
            -TEST_DISPLAY_WIDTH,
            "full-width column must align exactly"
        );
        // Starting on the next column, the opposite flick must return to the
        // previous full-width column with the same thresholds.
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(-delta), Event::TouchpadUp],
        );
        assert_eq!(
            settled(&mut h),
            0,
            "flick snapping works toward either edge"
        );
    }
}

#[test]
fn slow_release_or_insufficient_projected_visibility_never_snaps() {
    let mut slow = harness(1.0, 0.8, 0.55, true, false);
    frame(&mut slow, [Event::TouchpadDown]);
    for _ in 0..64 {
        frame(&mut slow, [swipe(0.01)]);
    }
    frame(&mut slow, [Event::TouchpadUp]);
    let slow_end = settled(&mut slow);
    assert!(
        slow_end < -700 && slow_end > -900,
        "a slow drag may reveal most of the window and still not snap: {slow_end}"
    );

    for (delta, visible) in [(0.025, 0.55), (0.06, 0.95)] {
        let mut short = harness(1.0, 0.8, visible, true, false);
        frame(
            &mut short,
            [Event::TouchpadDown, swipe(delta), Event::TouchpadUp],
        );
        let end = settled(&mut short);
        assert!(
            end < -100 && end > -1000,
            "fast but short flings must stop between columns: {end}"
        );
    }
}

#[test]
fn touching_again_and_pausing_before_release_cancel_a_flick() {
    let mut h = harness(1.0, 0.8, 0.55, true, false);
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(0.06), Event::TouchpadUp],
    );
    frame(&mut h, [Event::TouchpadDown]);
    let interrupted = offset(&mut h);
    h.advance(Duration::from_millis(200));
    assert_eq!(offset(&mut h), interrupted);
    frame(&mut h, [Event::TouchpadUp]);
    assert_eq!(
        settled(&mut h),
        interrupted,
        "a new touch cancels the pending destination"
    );

    let mut h = harness(1.0, 0.8, 0.55, true, false);
    frame(&mut h, [Event::TouchpadDown, swipe(0.06)]);
    let stopped = offset(&mut h);
    h.advance(Duration::from_millis(200));
    frame(&mut h, [Event::TouchpadUp]);
    assert_eq!(
        settled(&mut h),
        stopped,
        "holding still before lifting must not launch stale velocity"
    );
}

#[test]
fn flick_snapping_can_be_disabled_for_every_column_width() {
    for ratio in [0.35, 0.65, 1.0, 1.4] {
        for (momentum, speed) in [(0.0, 0.8), (1.0, 0.0)] {
            let mut h = harness_with_tuning(momentum, speed, 0.55, Some(ratio), false, "");
            frame(
                &mut h,
                [Event::TouchpadDown, swipe(0.06), Event::TouchpadUp],
            );
            let end = settled(&mut h);
            assert!(
                end > -1000 && end < 0,
                "disabled snapping must not gain a destination: {end}"
            );
        }
    }
}

#[test]
fn half_width_snaps_to_both_edges_ignoring_legacy_size_filter() {
    for reversed in [false, true] {
        let mut h = harness_with_tuning(
            1.0,
            0.8,
            0.55,
            Some(0.5),
            reversed,
            "snap_half_width = true",
        );
        let delta = if reversed { -0.03 } else { 0.03 };
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(delta), Event::TouchpadUp],
        );
        assert_eq!(settled(&mut h), -TEST_DISPLAY_WIDTH / 2);
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(-delta), Event::TouchpadUp],
        );
        assert_eq!(settled(&mut h), 0);
    }
    let mut h = harness_with_tuning(1.0, 0.8, 0.55, Some(0.5), false, "snap_half_width = false");
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(0.03), Event::TouchpadUp],
    );
    assert_eq!(
        settled(&mut h),
        -TEST_DISPLAY_WIDTH / 2,
        "legacy size flags no longer exclude Ribbon windows"
    );

    // A full-width first column followed by halves creates distinct left and
    // right alignments: the second column reaches the right edge at -512.
    let mut h = harness_with_tuning(1.0, 0.8, 0.55, Some(0.5), false, "snap_half_width = true");
    h.run(vec![Event::Command {
        command: Command::Window(Operation::SetWidth(1.0)),
    }]);
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(0.03), Event::TouchpadUp],
    );
    assert_eq!(settled(&mut h), -TEST_DISPLAY_WIDTH / 2);
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(0.03), Event::TouchpadUp],
    );
    assert_eq!(settled(&mut h), -TEST_DISPLAY_WIDTH);
}

#[test]
fn animation_speed_is_independent_of_flick_qualification() {
    let mut progress = Vec::new();
    for animation in [0.5, 2.0] {
        let mut h = harness_with_tuning(
            1.0,
            0.8,
            0.55,
            Some(1.0),
            false,
            &format!("snap_animation = {animation}"),
        );
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(0.06), Event::TouchpadUp],
        );
        h.advance(Duration::from_millis(200));
        progress.push(offset(&mut h));
        assert_eq!(settled(&mut h), -TEST_DISPLAY_WIDTH);
        // Changing only animation speed must not make a slow release snap.
        frame(&mut h, [Event::TouchpadDown]);
        for _ in 0..12 {
            frame(&mut h, [swipe(0.005)]);
        }
        frame(&mut h, [Event::TouchpadUp]);
        let end = settled(&mut h);
        assert!(end < -TEST_DISPLAY_WIDTH && end > -TEST_DISPLAY_WIDTH - 200);
    }
    assert!(
        progress[1] < progress[0] - 150,
        "faster animation settles sooner: {progress:?}"
    );
}

#[test]
fn free_exit_keeps_small_swipe_progress_and_optional_return_zone_is_tunable() {
    for (snap_back, exit_distance, returns) in
        [(false, 0.12, false), (true, 0.12, true), (true, 0.0, false)]
    {
        let mut h = harness_with_tuning(
            1.0,
            0.8,
            0.55,
            Some(1.0),
            false,
            &format!("snap_back = {snap_back}\nsnap_exit_distance = {exit_distance}"),
        );
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(0.06), Event::TouchpadUp],
        );
        assert_eq!(settled(&mut h), -TEST_DISPLAY_WIDTH);
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(0.005), Event::TouchpadUp],
        );
        let released = offset(&mut h);
        let end = settled(&mut h);
        if returns {
            assert_eq!(end, -TEST_DISPLAY_WIDTH);
        } else {
            assert!(
                end <= released && end < -TEST_DISPLAY_WIDTH,
                "free exit cannot undo progress"
            );
        }
    }
    // The return zone is cleared by sufficient projected travel, even if the
    // release is too slow to trigger a new forward snap.
    let mut h = harness_with_tuning(
        1.0,
        0.8,
        0.55,
        Some(1.0),
        false,
        "snap_back = true\nsnap_exit_distance = 0.02",
    );
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(0.005), Event::TouchpadUp],
    );
    assert!(settled(&mut h) < 0);
}

#[test]
fn high_decay_stops_sooner_without_changing_finger_motion() {
    let mut distances = Vec::new();
    for decay in [10.0, 40.0, 100.0] {
        let mut h = harness_with_tuning(
            1.0,
            0.0,
            0.55,
            None,
            false,
            &format!("deceleration = {decay}"),
        );
        frame(&mut h, [Event::TouchpadDown, swipe(0.06)]);
        assert_eq!(offset(&mut h), -61);
        frame(&mut h, [Event::TouchpadUp]);
        distances.push(settled(&mut h));
    }
    assert!(
        distances[0] < distances[1] && distances[1] < distances[2],
        "higher decay shortens coast: {distances:?}"
    );
}

#[test]
fn free_exit_never_pulls_back_to_a_column_already_passed() {
    for snap_back in [false, true] {
        let mut h = harness_with_tuning(
            1.0,
            0.8,
            0.55,
            Some(1.0),
            false,
            &format!("deceleration = 100.0\nsnap_back = {snap_back}"),
        );
        frame(&mut h, [Event::TouchpadDown, swipe(1.02)]);
        let dragged = offset(&mut h);
        frame(&mut h, [Event::TouchpadUp]);
        let end = settled(&mut h);
        if snap_back {
            assert_eq!(end, -TEST_DISPLAY_WIDTH);
        } else {
            assert!(
                end <= dragged,
                "a forward flick cannot pull back after passing an alignment"
            );
        }
    }
}

#[test]
fn paging_commits_even_tiny_slow_or_paused_swipes_independently_of_free_scroll_tuning() {
    for (width, reversed) in [(1.0, false), (0.5, false), (1.0, true), (0.5, true)] {
        let mut h = harness_with_tuning(
            0.0,
            0.0,
            0.95,
            Some(width),
            reversed,
            "three_finger_paging = true\nsnap_full_width = false\nsnap_half_width = false\nsnap_back = true\nsnap_exit_distance = 0.5\nsensitivity = 0.2",
        );
        let delta = if reversed { -0.00001 } else { 0.00001 };
        frame(&mut h, [Event::TouchpadDown, swipe(delta)]);
        let dragged = offset(&mut h);
        h.advance(Duration::from_millis(300));
        assert_eq!(
            offset(&mut h),
            dragged,
            "fingers still control progress until lift"
        );
        frame(&mut h, [Event::TouchpadUp]);
        let expected = if width > 0.75 {
            -TEST_DISPLAY_WIDTH
        } else {
            -TEST_DISPLAY_WIDTH / 2
        };
        assert_eq!(
            settled(&mut h),
            expected,
            "any swipe commits exactly one adjacent snap"
        );
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(-delta), Event::TouchpadUp],
        );
        assert_eq!(
            settled(&mut h),
            0,
            "paging exits without an effort threshold"
        );
    }
}

#[test]
fn paging_never_skips_a_destination_or_repeats_within_the_same_contact() {
    let mut h = harness_with_tuning(
        3.0,
        0.1,
        0.25,
        Some(1.0),
        false,
        "three_finger_paging = true",
    );
    frame(&mut h, [Event::TouchpadDown]);
    for _ in 0..20 {
        frame(&mut h, [swipe(0.3)]);
        assert!(offset(&mut h) >= -TEST_DISPLAY_WIDTH);
    }
    h.advance(Duration::from_millis(300));
    assert_eq!(offset(&mut h), -TEST_DISPLAY_WIDTH);
    frame(&mut h, [Event::TouchpadUp]);
    assert_eq!(settled(&mut h), -TEST_DISPLAY_WIDTH);
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(0.001), Event::TouchpadUp],
    );
    assert_eq!(settled(&mut h), -2 * TEST_DISPLAY_WIDTH);
}

#[test]
fn paging_uses_net_direction_and_clamps_at_strip_edges() {
    let mut h = harness_with_tuning(
        1.0,
        0.8,
        0.55,
        Some(1.0),
        false,
        "three_finger_paging = true",
    );
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(-0.01), Event::TouchpadUp],
    );
    assert_eq!(settled(&mut h), 0, "no destination beyond the first window");
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(0.01), Event::TouchpadUp],
    );
    assert_eq!(settled(&mut h), -TEST_DISPLAY_WIDTH);
    frame(&mut h, [Event::TouchpadDown, swipe(0.03)]);
    frame(&mut h, [swipe(-0.04), Event::TouchpadUp]);
    assert_eq!(
        settled(&mut h),
        0,
        "reversing before lift chooses the net swipe direction"
    );
    h.run(vec![Event::Command {
        command: Command::Window(Operation::Focus(Direction::Last)),
    }]);
    let last = offset(&mut h);
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(0.01), Event::TouchpadUp],
    );
    assert_eq!(
        settled(&mut h),
        last,
        "no destination beyond the last window"
    );
}

#[test]
fn paging_recovers_missing_contact_phases_and_leaves_modifier_scrolling_unchanged() {
    let mut h = harness_with_tuning(
        0.0,
        0.0,
        0.55,
        Some(1.0),
        false,
        "three_finger_paging = true",
    );
    frame(&mut h, [swipe(0.001)]);
    assert_eq!(
        settled(&mut h),
        -TEST_DISPLAY_WIDTH,
        "timeout releases a gesture with missing phases"
    );
    frame(
        &mut h,
        [
            Event::TouchpadDown,
            Event::Scroll { delta: 1.0 },
            Event::TouchpadUp,
        ],
    );
    let end = settled(&mut h);
    assert!(
        end < -TEST_DISPLAY_WIDTH && end > -TEST_DISPLAY_WIDTH - 100,
        "wheel remains free scrolling with zero momentum: {end}"
    );
    frame(
        &mut h,
        [
            Event::TouchpadDown,
            Event::Swipe {
                delta: 0.5,
                fingers: 4,
            },
            Event::TouchpadUp,
        ],
    );
    h.advance(Duration::from_millis(200));
    assert_eq!(offset(&mut h), end, "other finger counts do not page");
}

#[test]
fn paging_handles_mixed_widths_and_a_new_contact_interrupts_the_snap() {
    let mut h = harness_with_tuning(
        0.0,
        0.0,
        0.55,
        Some(0.5),
        false,
        "three_finger_paging = true",
    );
    h.run(vec![Event::Command {
        command: Command::Window(Operation::SetWidth(1.0)),
    }]);
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(0.001), Event::TouchpadUp],
    );
    assert_eq!(
        settled(&mut h),
        -TEST_DISPLAY_WIDTH / 2,
        "first half arrives at the trailing edge"
    );
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(0.001), Event::TouchpadUp],
    );
    frame(&mut h, [Event::TouchpadDown]);
    let interrupted = offset(&mut h);
    h.advance(Duration::from_millis(300));
    assert_eq!(offset(&mut h), interrupted);
    frame(&mut h, [Event::TouchpadUp]);
    assert_eq!(
        settled(&mut h),
        interrupted,
        "a touch alone cancels without launching a page"
    );
}

#[test]
fn paging_reaches_a_nonstandard_width_last_window_and_returns() {
    for reversed in [false, true] {
        let mut h = harness_with_tuning(
            0.0,
            0.0,
            0.55,
            Some(1.0),
            reversed,
            "three_finger_paging = true\nsnap_full_width = false\nsnap_half_width = false",
        );
        h.run(vec![
            Event::Command {
                command: Command::Window(Operation::Focus(Direction::Last)),
            },
            Event::Command {
                command: Command::Window(Operation::SetWidth(0.65)),
            },
            Event::Command {
                command: Command::Window(Operation::Focus(Direction::West)),
            },
        ]);
        let previous = offset(&mut h);
        let delta = if reversed { -0.001 } else { 0.001 };
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(delta), Event::TouchpadUp],
        );
        let last = previous - round_px(f64::from(TEST_DISPLAY_WIDTH) * 0.65);
        assert_eq!(
            settled(&mut h),
            last,
            "a constrained-width last window must become fully visible"
        );
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(delta), Event::TouchpadUp],
        );
        assert_eq!(settled(&mut h), last, "stop at the actual strip edge");
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(-delta), Event::TouchpadUp],
        );
        assert_eq!(settled(&mut h), previous);
    }
}

#[test]
fn paging_visits_both_edges_of_nonstandard_columns_without_skipping_them() {
    for ratio in [0.3, 0.65, 0.8, 0.95, 1.3] {
        let mut h = harness_with_tuning(
            0.0,
            0.0,
            0.55,
            Some(1.0),
            false,
            "three_finger_paging = true",
        );
        h.run(vec![
            Event::Command {
                command: Command::Window(Operation::Focus(Direction::East)),
            },
            Event::Command {
                command: Command::Window(Operation::SetWidth(ratio)),
            },
            Event::Command {
                command: Command::Window(Operation::Focus(Direction::First)),
            },
        ]);
        let custom_width = round_px(f64::from(TEST_DISPLAY_WIDTH) * ratio);
        let near = -custom_width.min(TEST_DISPLAY_WIDTH);
        let far = -custom_width.max(TEST_DISPLAY_WIDTH);
        let next = -TEST_DISPLAY_WIDTH - custom_width;
        for expected in [near, far, next] {
            frame(&mut h, [Event::TouchpadDown, swipe(3.0)]);
            assert_eq!(offset(&mut h), expected, "drag stops at one alignment");
            frame(&mut h, [Event::TouchpadUp]);
            assert_eq!(settled(&mut h), expected, "column width ratio {ratio}");
        }
        for expected in [far, near, 0] {
            frame(
                &mut h,
                [Event::TouchpadDown, swipe(-0.001), Event::TouchpadUp],
            );
            assert_eq!(settled(&mut h), expected, "return at width ratio {ratio}");
        }
    }
}

fn columns(h: &mut TestHarness) -> Vec<Entity> {
    let world = h.world();
    world
        .query_filtered::<&LayoutStrip, With<ActiveWorkspaceMarker>>()
        .single(world)
        .expect("active ribbon")
        .all_columns()
}

fn window_x(h: &mut TestHarness, entity: Entity) -> i32 {
    h.world()
        .get::<Position>(entity)
        .expect("window position")
        .x
}

fn magnetic_harness(momentum: f64, width: f64, reversed: bool, tuning: &str) -> TestHarness {
    harness_with_tuning(
        momentum,
        0.0,
        0.95,
        Some(width),
        reversed,
        &format!("magnetic_snapping = true\nthree_finger_paging = true\n{tuning}"),
    )
}

#[test]
fn magnetic_medium_flick_catches_next_edge_and_fast_flick_skips_it_with_paging_enabled() {
    for reversed in [false, true] {
        for (delta, destination) in [(0.08, 1), (0.16, 2)] {
            let mut h = magnetic_harness(1.0, 1.0, reversed, "");
            let delta = if reversed { -delta } else { delta };
            frame(
                &mut h,
                [Event::TouchpadDown, swipe(delta), Event::TouchpadUp],
            );
            assert_eq!(settled(&mut h), -destination * TEST_DISPLAY_WIDTH);
            frame(
                &mut h,
                [Event::TouchpadDown, swipe(-delta), Event::TouchpadUp],
            );
            assert_eq!(
                settled(&mut h),
                0,
                "the opposite flick returns symmetrically"
            );
        }
    }
}

#[test]
fn magnetic_precise_drag_catches_after_lift_but_never_moves_stationary_fingers() {
    let mut h = magnetic_harness(1.0, 1.0, false, "");
    frame(&mut h, [Event::TouchpadDown]);
    for _ in 0..46 {
        frame(&mut h, [swipe(0.02)]);
    }
    let dragged = offset(&mut h);
    assert_eq!(dragged, round_px(-0.92 * f64::from(TEST_DISPLAY_WIDTH)));
    h.advance(Duration::from_millis(300));
    assert_eq!(offset(&mut h), dragged);
    frame(&mut h, [Event::TouchpadUp]);
    let during = offset(&mut h);
    assert!(
        during < dragged && during > -TEST_DISPLAY_WIDTH,
        "capture uses a spring"
    );
    assert_eq!(settled(&mut h), -TEST_DISPLAY_WIDTH);
}

#[test]
fn magnetic_range_and_strength_sliders_change_capture_without_changing_drag_distance() {
    for (range, catches) in [(0.03, false), (0.2, true)] {
        let mut h = magnetic_harness(0.0, 1.0, false, &format!("magnet_range = {range}"));
        frame(&mut h, [Event::TouchpadDown, swipe(0.88)]);
        assert_eq!(
            offset(&mut h),
            round_px(-0.88 * f64::from(TEST_DISPLAY_WIDTH))
        );
        frame(&mut h, [Event::TouchpadUp]);
        let end = settled(&mut h);
        assert_eq!(end, if catches { -TEST_DISPLAY_WIDTH } else { -901 });
    }
    for (strength, destination) in [(1.8, 2), (6.0, 1)] {
        let mut h = magnetic_harness(1.0, 1.0, false, &format!("magnet_strength = {strength}"));
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(0.16), Event::TouchpadUp],
        );
        assert_eq!(settled(&mut h), -destination * TEST_DISPLAY_WIDTH);
    }
}

#[test]
fn magnetic_momentum_tuning_applies_even_when_three_finger_paging_is_enabled() {
    for (momentum, destination) in [(0.5, 1), (1.0, 2), (1.5, 3)] {
        let mut h = magnetic_harness(momentum, 1.0, false, "");
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(0.16), Event::TouchpadUp],
        );
        assert_eq!(settled(&mut h), -destination * TEST_DISPLAY_WIDTH);
    }
}

#[test]
fn magnetic_short_inaccurate_drag_stays_between_edges_and_zero_momentum_still_catches_nearby() {
    for (delta, expected) in [(0.6, -614), (0.92, -TEST_DISPLAY_WIDTH), (0.08, 0)] {
        let mut h = magnetic_harness(0.0, 1.0, false, "");
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(delta), Event::TouchpadUp],
        );
        assert_eq!(settled(&mut h), expected);
    }
}

#[test]
fn magnetic_edges_include_half_nonstandard_and_oversized_columns() {
    for (ratio, drag, target) in [(0.5, 0.46, -512), (0.65, 0.31, -308), (1.4, 0.36, -410)] {
        let mut h = magnetic_harness(
            0.0,
            ratio,
            false,
            "snap_full_width = false\nsnap_half_width = false",
        );
        // The trailing edge of the next 65%-width column aligns at -30%;
        // an oversized column's own trailing edge aligns at -40%.
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(drag), Event::TouchpadUp],
        );
        assert_eq!(settled(&mut h), target, "width ratio {ratio}");
    }
}

#[test]
fn magnetic_new_touch_interrupts_capture_and_keyboard_navigation_cancels_it() {
    let mut h = magnetic_harness(1.0, 1.0, false, "");
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(0.08), Event::TouchpadUp],
    );
    h.advance(Duration::from_millis(350));
    frame(&mut h, [Event::TouchpadDown]);
    let interrupted = offset(&mut h);
    h.advance(Duration::from_millis(300));
    assert_eq!(offset(&mut h), interrupted);
    frame(&mut h, [swipe(-0.1)]);
    assert!(
        offset(&mut h) > interrupted,
        "new input owns the offset immediately"
    );
    h.run(vec![Event::Command {
        command: Command::Window(Operation::Focus(Direction::First)),
    }]);
    assert_eq!(offset(&mut h), 0);
    h.advance(Duration::from_secs(2));
    assert_eq!(offset(&mut h), 0);
}

#[test]
fn magnetic_wheel_timeout_can_capture_with_momentum_off() {
    let mut h = magnetic_harness(0.0, 1.0, false, "");
    // A wheel sequence has no TouchpadDown/Up. At sensitivity 1 its scale is .0775.
    frame(
        &mut h,
        [Event::Scroll {
            delta: 0.92 / 0.0775,
        }],
    );
    assert_eq!(settled(&mut h), -TEST_DISPLAY_WIDTH);
}

#[test]
fn magnetic_infinite_ribbon_catches_across_both_sides_of_the_seam() {
    let mut h = magnetic_harness(1.0, 1.0, false, "infinite_ribbon = true");
    let order = columns(&mut h);
    h.run(vec![Event::Command {
        command: Command::Window(Operation::Focus(Direction::Last)),
    }]);
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(0.16), Event::TouchpadUp],
    );
    assert_eq!(settled(&mut h), -TEST_DISPLAY_WIDTH);
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(-0.16), Event::TouchpadUp],
    );
    assert_eq!(settled(&mut h), -11 * TEST_DISPLAY_WIDTH);
    assert_eq!(columns(&mut h), order);
}

#[test]
fn infinite_paging_loops_in_both_directions_without_changing_window_order() {
    for reversed in [false, true] {
        let mut h = harness_with_tuning(
            0.0,
            0.0,
            0.55,
            Some(1.0),
            reversed,
            "three_finger_paging = true\ninfinite_ribbon = true",
        );
        let order = columns(&mut h);
        let delta = if reversed { -0.001 } else { 0.001 };
        // Two whole laps verify normalization and that every gesture still
        // selects exactly one adjacent window.
        for step in 1..=24 {
            frame(
                &mut h,
                [Event::TouchpadDown, swipe(delta), Event::TouchpadUp],
            );
            let expected = -i32::try_from(step % 12).unwrap() * TEST_DISPLAY_WIDTH;
            assert_eq!(settled(&mut h), expected, "forward step {step}");
            assert_eq!(window_x(&mut h, order[step % 12]), 0);
            assert_eq!(columns(&mut h), order);
        }
        for step in 1..=24 {
            frame(
                &mut h,
                [Event::TouchpadDown, swipe(-delta), Event::TouchpadUp],
            );
            let index = (12 - step % 12) % 12;
            assert_eq!(
                settled(&mut h),
                -i32::try_from(index).unwrap() * TEST_DISPLAY_WIDTH
            );
            assert_eq!(window_x(&mut h, order[index]), 0);
        }
    }
}

#[test]
fn infinite_free_scroll_keeps_columns_adjacent_across_the_seam_and_multiple_laps() {
    let mut h = harness_with_tuning(0.0, 0.0, 0.55, Some(1.0), false, "infinite_ribbon = true");
    let order = columns(&mut h);
    h.run(vec![Event::Command {
        command: Command::Window(Operation::Focus(Direction::Last)),
    }]);
    frame(&mut h, [Event::TouchpadDown, swipe(0.25)]);
    // At the join, the tail of the last column and the head of the first
    // occupy one continuous screen, with no backward traversal or reorder.
    assert_eq!(window_x(&mut h, order[11]), -256);
    assert_eq!(window_x(&mut h, order[0]), 768);
    frame(&mut h, [swipe(36.5), Event::TouchpadUp]);
    assert_eq!(settled(&mut h), -12_032);
    assert_eq!(window_x(&mut h, order[11]), -768);
    assert_eq!(window_x(&mut h, order[0]), 256);
    assert_eq!(columns(&mut h), order);
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(-0.75), Event::TouchpadUp],
    );
    assert_eq!(settled(&mut h), -11 * TEST_DISPLAY_WIDTH);
    assert_eq!(window_x(&mut h, order[11]), 0);
}

#[test]
fn infinite_flick_preserves_its_forward_snap_through_the_join() {
    let mut h = harness_with_tuning(1.0, 0.8, 0.55, Some(1.0), false, "infinite_ribbon = true");
    let order = columns(&mut h);
    h.run(vec![Event::Command {
        command: Command::Window(Operation::Focus(Direction::Last)),
    }]);
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(0.06), Event::TouchpadUp],
    );
    assert_eq!(settled(&mut h), 0);
    assert_eq!(window_x(&mut h, order[0]), 0);
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(-0.06), Event::TouchpadUp],
    );
    assert_eq!(settled(&mut h), -11 * TEST_DISPLAY_WIDTH);
    assert_eq!(window_x(&mut h, order[11]), 0);
}

#[test]
fn disabling_an_infinite_ribbon_restores_bounds_and_keeps_the_visible_window() {
    let mut h = harness_with_tuning(0.0, 0.0, 0.55, Some(1.0), false, "infinite_ribbon = true");
    let order = columns(&mut h);
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(-0.25), Event::TouchpadUp],
    );
    settled(&mut h);
    assert_eq!(window_x(&mut h, order[0]), 256);
    // Use an ordinary non-looping configuration as a live reload.
    let mut bounded = harness(0.0, 0.0, 0.55, true, false);
    let config = bounded.world().resource::<Config>().clone();
    #[cfg(feature = "lua")]
    h.world().resource::<Config>().replace_inner_from(&config);
    #[cfg(not(feature = "lua"))]
    h.world().insert_resource(config);
    h.advance(Duration::from_millis(500));
    assert_eq!(offset(&mut h), 0);
    assert_eq!(window_x(&mut h, order[0]), 0);
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(-1.0), Event::TouchpadUp],
    );
    assert_eq!(settled(&mut h), 0, "the first-window boundary is restored");
    h.run(vec![Event::Command {
        command: Command::Window(Operation::Focus(Direction::Last)),
    }]);
    frame(&mut h, [Event::TouchpadDown, swipe(1.0), Event::TouchpadUp]);
    assert_eq!(settled(&mut h), -11 * TEST_DISPLAY_WIDTH);
    assert_eq!(columns(&mut h), order);
}

#[test]
fn infinite_short_ribbons_reuse_each_window_and_single_columns_keep_their_bounds() {
    let mut template =
        harness_with_tuning(0.0, 0.0, 0.55, Some(0.5), false, "infinite_ribbon = true");
    let config = template.world().resource::<Config>().clone();
    for count in [1, 2] {
        let mut h = TestHarness::new()
            .with_config(config.clone())
            .with_windows(count);
        h.run(vec![
            Event::MenuOpened { window_id: 0 },
            Event::Command {
                command: Command::Window(Operation::Focus(Direction::First)),
            },
        ]);
        let order = columns(&mut h);
        frame(&mut h, [Event::TouchpadDown, swipe(0.5), Event::TouchpadUp]);
        let end = settled(&mut h);
        if count == 1 {
            assert_eq!(end, 0, "a lone half-width window cannot loop into itself");
        } else {
            assert_eq!(window_x(&mut h, order[1]), 0);
            frame(&mut h, [Event::TouchpadDown, swipe(1.0), Event::TouchpadUp]);
            assert_eq!(settled(&mut h), 0);
            assert_eq!(window_x(&mut h, order[0]), 0);
        }
        assert_eq!(columns(&mut h), order);
    }
}

#[test]
fn infinite_paging_reaches_half_width_columns_on_either_side_of_the_join() {
    let mut h = harness_with_tuning(
        0.0,
        0.0,
        0.55,
        Some(0.5),
        false,
        "infinite_ribbon = true\nthree_finger_paging = true",
    );
    let order = columns(&mut h);
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(-0.001), Event::TouchpadUp],
    );
    assert_eq!(settled(&mut h), -11 * TEST_DISPLAY_WIDTH / 2);
    assert_eq!(window_x(&mut h, order[11]), 0);
    assert_eq!(window_x(&mut h, order[0]), TEST_DISPLAY_WIDTH / 2);
    frame(
        &mut h,
        [Event::TouchpadDown, swipe(0.001), Event::TouchpadUp],
    );
    assert_eq!(settled(&mut h), 0);
    assert_eq!(window_x(&mut h, order[0]), 0);
}

#[test]
fn trackpad_haptics_click_once_per_committed_page_and_only_when_enabled() {
    let played = |h: &mut TestHarness| {
        h.world()
            .resource::<crate::ecs::scroll::SnapHaptics>()
            .played
    };
    for (enabled, expected) in [(true, 2), (false, 0)] {
        let mut h = harness_with_tuning(
            0.0,
            0.0,
            0.95,
            Some(1.0),
            false,
            &format!("three_finger_paging = true\nhaptics = {enabled}"),
        );
        frame(&mut h, [Event::TouchpadDown, swipe(0.05)]);
        assert_eq!(played(&mut h), 0, "no click while the fingers are down");
        frame(&mut h, [Event::TouchpadUp]);
        assert_eq!(settled(&mut h), -TEST_DISPLAY_WIDTH);
        frame(
            &mut h,
            [Event::TouchpadDown, swipe(-0.05), Event::TouchpadUp],
        );
        assert_eq!(settled(&mut h), 0);
        assert_eq!(played(&mut h), expected, "one click per page");
    }
}
