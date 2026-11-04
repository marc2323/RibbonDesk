//! Floating windows that ride along with the ribbon.
//!
//! A floating window is not a column, but with `floating_follows_ribbon` it
//! keeps the horizontal offset from the ribbon it had when it started floating
//! or was last dragged. Scrolling the ribbon carries it along by the same
//! distance, wrapping with the columns on an infinite ribbon and parking at a
//! screen edge sliver like they do.
//!
//! With `floating_on_top` they also stay above the ribbon's tiles in the
//! window order: when a click or a focus change puts a tile over a floating
//! window, the floating window is lifted back on top and the tile keeps focus.

use bevy::ecs::change_detection::{DetectChanges, Ref};
use bevy::ecs::component::Component;
use bevy::ecs::entity::{Entity, EntityHashMap};
use bevy::ecs::hierarchy::ChildOf;
use bevy::ecs::message::MessageReader;
use bevy::ecs::query::{Added, Has, With, Without};
use bevy::ecs::resource::Resource;
use bevy::ecs::system::{Commands, Local, Populated, Query, Res, ResMut};
use bevy::math::IRect;
use bevy::time::Time;
use std::collections::HashMap;
use std::time::Duration;
use tracing::{Level, debug, instrument, trace};

use super::display::FloatingLayer;
use super::focus::FocusHistory;
use super::layout::{LayoutStrip, PARKED_STRIP_SLIVER, looped_window_x};
use super::params::{ActiveDisplay, Windows};
use super::{
    ActiveWorkspaceMarker, Bounds, DockPosition, FocusedMarker, MissionControlActive,
    MouseHeldMarker, NextWake, Position, RepositionMarker, Scrolling, Unmanaged,
};
use crate::commands::visible_floating_entities;
use crate::config::Config;
use crate::events::{Event, InputEvent};
use crate::manager::{Application, Display, Origin, Window, WindowManager};
use crate::platform::WinID;

/// How long after the ribbon last moved a floating window's frame still counts
/// as the ribbon's doing. Move notifications for frames the strip has already
/// left can arrive this late; within the window they are overwritten instead
/// of being read as the user dragging the window somewhere new.
pub(crate) const ANCHOR_SETTLE: Duration = Duration::from_millis(300);

/// The ribbon a floating window follows, and where it sits relative to it.
#[derive(Clone, Component, Copy, Debug, PartialEq, Eq)]
pub struct RibbonAnchor {
    /// The [`LayoutStrip`] entity the window moves with.
    pub strip: Entity,
    /// The window's origin x minus the strip's origin x.
    pub offset_x: i32,
}

type FloatingWindows<'w, 's> = Populated<
    'w,
    's,
    (
        Entity,
        &'static Unmanaged,
        &'static mut Position,
        &'static Bounds,
        Option<&'static RibbonAnchor>,
        Has<RepositionMarker>,
    ),
    (With<Window>, Without<LayoutStrip>),
>;

type ActiveStrips<'w, 's> = Query<
    'w,
    's,
    (
        Entity,
        &'static LayoutStrip,
        Ref<'static, Position>,
        &'static ChildOf,
        Has<Scrolling>,
        Has<RepositionMarker>,
    ),
    (With<ActiveWorkspaceMarker>, Without<Window>),
>;

/// Where a window anchored at strip-relative `x` lands: on the visible lap of
/// an infinite ribbon, and parked as an edge sliver once wholly off screen.
pub(crate) fn anchored_window_x(
    x: i32,
    width: i32,
    viewport: IRect,
    period: Option<i32>,
    sliver: i32,
) -> i32 {
    let x = period.map_or(x, |period| {
        looped_window_x(x, width, viewport.min.x, period)
    });
    if x + width <= viewport.min.x {
        viewport.min.x - width + sliver
    } else if x >= viewport.max.x {
        viewport.max.x - sliver
    } else {
        x
    }
}

/// Moves anchored floating windows with their ribbon, anchors new ones, and
/// re-anchors a window the user moved while the ribbon was still.
#[allow(clippy::too_many_arguments)]
#[instrument(level = Level::DEBUG, skip_all)]
pub(super) fn follow_ribbon_anchors(
    mut floating: FloatingWindows,
    strips: ActiveStrips,
    frames: Query<&Bounds, (With<Window>, Without<LayoutStrip>)>,
    displays: Query<(&Display, Option<&DockPosition>)>,
    config: Res<Config>,
    time: Res<Time>,
    mut last_motion: Local<EntityHashMap<Duration>>,
    mut commands: Commands,
) {
    let enabled = config.floating_follows_ribbon();
    let now = time.elapsed();
    last_motion.retain(|strip, _| strips.contains(*strip));
    for (entity, _, position, _, scrolling, repositioning) in &strips {
        if position.is_changed() || scrolling || repositioning {
            last_motion.insert(entity, now);
        }
    }
    let viewport_of = |strip: Entity| {
        let (_, _, _, child_of, _, _) = strips.get(strip).ok()?;
        let (display, dock) = displays.get(child_of.parent()).ok()?;
        Some(display.actual_display_bounds(dock, &config))
    };

    for (entity, unmanaged, mut position, bounds, anchor, repositioning) in &mut floating {
        if !enabled || !matches!(unmanaged, Unmanaged::Floating) {
            if anchor.is_some()
                && let Ok(mut entity_commands) = commands.get_entity(entity)
            {
                entity_commands.try_remove::<RibbonAnchor>();
            }
            continue;
        }
        // Our own placement (a pop offset, a grid rule) is still animating;
        // anchor where it ends rather than where it started.
        if repositioning {
            continue;
        }
        let size = bounds.0;

        let Some(anchor) = anchor.filter(|anchor| strips.contains(anchor.strip)) else {
            let center = position.0 + size / 2;
            let strip = strips
                .iter()
                .find(|(strip, ..)| viewport_of(*strip).is_some_and(|v| v.contains(center)))
                .or_else(|| {
                    (strips.iter().count() == 1)
                        .then(|| strips.iter().next())
                        .flatten()
                });
            if let Some((strip, _, strip_position, ..)) = strip
                && let Ok(mut entity_commands) = commands.get_entity(entity)
            {
                trace!("anchoring floating {entity} to strip {strip}");
                entity_commands.try_insert(RibbonAnchor {
                    strip,
                    offset_x: position.x - strip_position.x,
                });
            }
            continue;
        };

        let Ok((_, layout, strip_position, _, _, _)) = strips.get(anchor.strip) else {
            continue;
        };
        let Some(viewport) = viewport_of(anchor.strip) else {
            continue;
        };
        // A parked (hidden) virtual row: its floats stay where they are.
        if strip_position.y >= viewport.max.y - PARKED_STRIP_SLIVER {
            continue;
        }
        let period = config
            .infinite_ribbon()
            .then(|| {
                layout.loop_period(viewport.width(), &|column| {
                    frames
                        .get(column)
                        .ok()
                        .map(|bounds| IRect::from_corners(Origin::ZERO, bounds.0))
                })
            })
            .flatten();
        let expected = anchored_window_x(
            strip_position.x + anchor.offset_x,
            size.x,
            viewport,
            period,
            config.sliver_width(),
        );
        if position.x == expected {
            continue;
        }

        let ribbon_moving = last_motion
            .get(&anchor.strip)
            .is_some_and(|moved| now.saturating_sub(*moved) < ANCHOR_SETTLE);
        if ribbon_moving {
            position.x = expected;
        } else if let Ok(mut entity_commands) = commands.get_entity(entity) {
            // The ribbon is still, so the window moved by itself: the user
            // dragged it, or its app placed it. Keep it where it is now.
            trace!("re-anchoring floating {entity} at {}", position.x);
            entity_commands.try_insert(RibbonAnchor {
                strip: anchor.strip,
                offset_x: position.x - strip_position.x,
            });
        }
    }
}

/// How long after a click or a focus change the window order is checked, so
/// the window server has finished raising whatever was clicked and our own
/// focus raises have landed.
pub(crate) const RESTACK_DELAY: Duration = Duration::from_millis(120);

/// When the window order is next checked for floating windows a tile has
/// covered, if a click or a focus change asked for it.
#[derive(Default, Resource)]
pub(crate) struct FloatRestackDue(pub(crate) Option<Duration>);

/// Schedules a stacking check after a click or after focus lands on a tile.
pub(super) fn request_float_restack(
    mut input: MessageReader<InputEvent>,
    focused_tiles: Query<(), (Added<FocusedMarker>, With<Window>, Without<Unmanaged>)>,
    time: Res<Time>,
    mut due: ResMut<FloatRestackDue>,
) {
    let clicked = input.read().fold(false, |clicked, InputEvent(event)| {
        clicked || matches!(event, Event::MouseUp { .. })
    });
    if clicked || !focused_tiles.is_empty() {
        due.0 = Some(time.elapsed() + RESTACK_DELAY);
    }
}

/// Which floating windows sit below a tile they overlap, deepest first so
/// raising them in order keeps their order among themselves. `order` is the
/// window server's on-screen list, front to back.
pub(crate) fn buried_floats(
    floats: &[(Entity, WinID, IRect)],
    tiles: &[(WinID, IRect)],
    order: &[WinID],
) -> Vec<Entity> {
    let rank: HashMap<WinID, usize> = order.iter().enumerate().map(|(i, id)| (*id, i)).collect();
    let mut buried = floats
        .iter()
        .filter_map(|(entity, id, frame)| {
            let depth = *rank.get(id)?;
            tiles
                .iter()
                .any(|(tile, tile_frame)| {
                    let overlap = frame.intersect(*tile_frame);
                    overlap.width() > 0
                        && overlap.height() > 0
                        && rank.get(tile).is_some_and(|tile_depth| *tile_depth < depth)
                })
                .then_some((depth, *entity))
        })
        .collect::<Vec<_>>();
    buried.sort_unstable_by_key(|(depth, _)| std::cmp::Reverse(*depth));
    buried.into_iter().map(|(_, entity)| entity).collect()
}

/// Lifts floating windows a tile has covered back above it.
///
/// An accessibility raise cannot put a window above another app's frontmost
/// window, so each buried floating window is focused with a raise, and then
/// focus goes back to the tile without raising it. The tile keeps focus and
/// the floating windows end up on top. Toggling the floating layer behind the
/// tiles on a workspace turns this off there.
#[allow(clippy::too_many_arguments)]
#[instrument(level = Level::DEBUG, skip_all)]
pub(super) fn keep_floating_on_top(
    mut due: ResMut<FloatRestackDue>,
    time: Res<Time>,
    mut next_wake: ResMut<NextWake>,
    windows: Windows,
    active_display: ActiveDisplay,
    strips: Query<Has<Scrolling>, With<ActiveWorkspaceMarker>>,
    mouse_held: Query<(), With<MouseHeldMarker>>,
    layers: Query<&FloatingLayer>,
    apps: Query<&Application>,
    window_manager: Res<WindowManager>,
    focus_history: Res<FocusHistory>,
    mission_control: Res<MissionControlActive>,
) {
    let Some(at) = due.0 else {
        return;
    };
    let now = time.elapsed();
    if now < at {
        next_wake.within(at - now);
        return;
    }
    // Not while the ribbon or a window is in the user's hands: check again
    // once they let go.
    if strips.iter().any(|scrolling| scrolling) || !mouse_held.is_empty() {
        due.0 = Some(now + RESTACK_DELAY);
        next_wake.within(RESTACK_DELAY);
        return;
    }
    due.0 = None;
    if mission_control.0 {
        return;
    }

    let strip = active_display.active_strip();
    let workspace_id = strip.id();
    if layers
        .iter()
        .any(|layer| layer.workspace_id == workspace_id && !layer.front)
    {
        return;
    }
    // Only a tile's focus is worth restoring this way; a focused floating
    // window is on top already.
    let Some((focused, focused_entity)) = windows.focused() else {
        return;
    };
    if !strip.contains(focused_entity) {
        return;
    }

    let display_bounds = active_display.bounds();
    let floats = visible_floating_entities(&windows, &window_manager, workspace_id, display_bounds)
        .into_iter()
        .filter_map(|entity| Some((entity, windows.get(entity)?.id(), windows.frame(entity)?)))
        .collect::<Vec<_>>();
    if floats.is_empty() {
        return;
    }
    let tiles = strip
        .all_windows()
        .into_iter()
        .filter_map(|entity| {
            let frame = windows.frame(entity)?;
            (!display_bounds.intersect(frame).is_empty())
                .then_some((windows.get(entity)?.id(), frame))
        })
        .collect::<Vec<_>>();
    let Some(order) = window_manager.windows_on_screen() else {
        return;
    };
    let mut buried = buried_floats(&floats, &tiles, &order);
    if buried.is_empty() {
        return;
    }
    // The floating window used last ends up on top.
    if let Some(last) = focus_history.last_floating(workspace_id)
        && let Some(index) = buried.iter().position(|entity| *entity == last)
    {
        let last = buried.remove(index);
        buried.push(last);
    }

    let Some(focused_psn) = windows.psn(focused.id(), &apps) else {
        return;
    };
    let mut on_top = None;
    for entity in buried {
        let Some(window) = windows.get(entity) else {
            continue;
        };
        let Some(psn) = windows.psn(window.id(), &apps) else {
            continue;
        };
        debug!("lifting floating window {} above the ribbon", window.id());
        window.focus_with_raise(psn);
        on_top = Some((window, psn));
    }
    if let Some((window, psn)) = on_top {
        focused.focus_without_raise(focused_psn, window, psn);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anchored_windows_park_as_slivers_and_wrap_with_the_ribbon() {
        let viewport = IRect::new(0, 0, 1000, 800);
        assert_eq!(anchored_window_x(200, 300, viewport, None, 5), 200);
        assert_eq!(anchored_window_x(-300, 300, viewport, None, 5), -295);
        assert_eq!(anchored_window_x(1200, 300, viewport, None, 5), 995);
        // Partly visible windows are left alone.
        assert_eq!(anchored_window_x(-100, 300, viewport, None, 5), -100);
        // One lap to the left of the visible copy comes back around.
        assert_eq!(
            anchored_window_x(200 - 3000, 300, viewport, Some(3000), 5),
            200
        );
        assert_eq!(
            anchored_window_x(200 + 3000, 300, viewport, Some(3000), 5),
            200
        );
    }

    #[test]
    fn only_floats_under_an_overlapping_tile_are_buried() {
        let mut world = bevy::ecs::world::World::new();
        let (a, b, c) = (
            world.spawn(()).id(),
            world.spawn(()).id(),
            world.spawn(()).id(),
        );
        let floats = [
            (a, 10, IRect::new(100, 100, 300, 300)),
            (b, 11, IRect::new(250, 100, 400, 300)),
            (c, 12, IRect::new(900, 100, 1000, 300)),
        ];
        let tiles = [
            (1, IRect::new(0, 0, 500, 800)),
            (2, IRect::new(500, 0, 1000, 800)),
        ];
        // 11 is above the tile it overlaps, 10 and 12 are below theirs.
        assert_eq!(
            buried_floats(&floats, &tiles, &[11, 1, 10, 2, 12]),
            vec![c, a]
        );
        // Everything above the tiles: nothing to do.
        assert!(buried_floats(&floats, &tiles, &[10, 11, 12, 1, 2]).is_empty());
        // Touching edges is not covering.
        let edge = [(a, 10, IRect::new(1000, 0, 1100, 100))];
        assert!(buried_floats(&edge, &tiles, &[1, 2, 10]).is_empty());
    }
}
