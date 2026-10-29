use std::time::Duration;

use bevy::prelude::*;

use crate::config::Config;
use crate::ecs::floating::{ANCHOR_SETTLE, RibbonAnchor};
use crate::ecs::{ActiveWorkspaceMarker, Position, Unmanaged, layout::LayoutStrip};
use crate::events::Event;

use super::*;

fn strip_x(world: &mut World) -> (Entity, i32) {
    let mut query = world
        .query_filtered::<(Entity, &Position), (With<LayoutStrip>, With<ActiveWorkspaceMarker>)>();
    let (entity, position) = query.single(world).expect("active strip");
    (entity, position.x)
}

fn float_state(world: &mut World, id: crate::platform::WinID) -> (i32, Option<RibbonAnchor>) {
    let entity = find_window_entity(id, world);
    let x = world.get::<Position>(entity).expect("window position").x;
    (x, world.get::<RibbonAnchor>(entity).copied())
}

fn floating_harness(follow: bool) -> TestHarness {
    let config =
        Config::try_from(format!("[options]\nfloating_follows_ribbon = {follow}\n").as_str())
            .expect("valid config");
    let mut harness = TestHarness::new().with_config(config).with_windows(4);
    harness.run(vec![Event::MenuOpened { window_id: 0 }]);
    let float = find_window_entity(3, harness.world());
    harness
        .world()
        .entity_mut(float)
        .insert(Unmanaged::Floating);
    harness.advance(Duration::from_secs(1));
    harness
}

#[test]
fn floating_window_scrolls_with_the_ribbon_and_keeps_a_dragged_offset() {
    let mut harness = floating_harness(true);

    let (strip, origin_x) = strip_x(harness.world());
    let (float_x, anchor) = float_state(harness.world(), 3);
    let anchor = anchor.expect("floating window is anchored");
    assert_eq!(anchor.strip, strip);
    assert_eq!(anchor.offset_x, float_x - origin_x);
    // Keep the window well inside the viewport so parking does not apply.
    let float = find_window_entity(3, harness.world());
    harness.world().get_mut::<Position>(float).expect("float").x = 300;
    harness.advance(Duration::from_secs(1));
    let (_, anchor) = float_state(harness.world(), 3);
    let offset = anchor.expect("still anchored").offset_x;
    assert_eq!(
        offset,
        300 - origin_x,
        "a move while the ribbon is still re-anchors"
    );

    // Scroll the ribbon: the float moves by the same distance.
    harness.world().get_mut::<Position>(strip).expect("strip").x = origin_x - 120;
    harness.advance(Duration::from_millis(100));
    let (moved_strip, now_x) = strip_x(harness.world());
    assert_eq!(moved_strip, strip);
    let (float_x, anchor) = float_state(harness.world(), 3);
    assert_eq!(float_x, now_x + offset);
    assert_eq!(
        anchor.expect("anchored").offset_x,
        offset,
        "scrolling keeps the offset"
    );

    // Once the ribbon settles, the anchor is unchanged.
    harness.advance(ANCHOR_SETTLE * 2);
    let (_, anchor) = float_state(harness.world(), 3);
    assert_eq!(anchor.expect("anchored").offset_x, offset);
}

#[test]
fn floating_window_stays_put_when_following_is_off() {
    let mut harness = floating_harness(false);
    let (strip, origin_x) = strip_x(harness.world());
    let (float_x, anchor) = float_state(harness.world(), 3);
    assert!(anchor.is_none());
    harness.world().get_mut::<Position>(strip).expect("strip").x = origin_x - 120;
    harness.advance(Duration::from_millis(200));
    assert_eq!(float_state(harness.world(), 3).0, float_x);
}

#[test]
fn managing_a_floating_window_drops_its_anchor() {
    let mut harness = floating_harness(true);
    let float = find_window_entity(3, harness.world());
    assert!(harness.world().get::<RibbonAnchor>(float).is_some());
    harness
        .world()
        .entity_mut(float)
        .insert(Unmanaged::Minimized);
    harness.advance(Duration::from_millis(100));
    assert!(harness.world().get::<RibbonAnchor>(float).is_none());
}
