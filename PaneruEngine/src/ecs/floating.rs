//! Floating windows that ride along with the ribbon.
//!
//! A floating window is not a column, but with `floating_follows_ribbon` it
//! keeps the horizontal offset from the ribbon it had when it started floating
//! or was last dragged. Scrolling the ribbon carries it along by the same
//! distance, wrapping with the columns on an infinite ribbon and parking at a
//! screen edge sliver like they do.

use bevy::ecs::change_detection::{DetectChanges, Ref};
use bevy::ecs::component::Component;
use bevy::ecs::entity::{Entity, EntityHashMap};
use bevy::ecs::hierarchy::ChildOf;
use bevy::ecs::query::{Has, With, Without};
use bevy::ecs::system::{Commands, Local, Populated, Query, Res};
use bevy::math::IRect;
use bevy::time::Time;
use std::time::Duration;
use tracing::{Level, instrument, trace};

use super::layout::{LayoutStrip, PARKED_STRIP_SLIVER, looped_window_x};
use super::{
    ActiveWorkspaceMarker, Bounds, DockPosition, Position, RepositionMarker, Scrolling, Unmanaged,
};
use crate::config::Config;
use crate::manager::{Display, Origin, Window};

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
}
