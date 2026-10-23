use bevy::app::{App, Plugin, Update};
use bevy::ecs::entity::Entity;
use bevy::ecs::message::MessageReader;
use bevy::ecs::query::{With, Without};
use bevy::ecs::schedule::IntoScheduleConfigs as _;
use bevy::ecs::system::{Commands, Local, Populated, Res, Single};
use bevy::math::IRect;
use bevy::time::Time;
use std::time::{Duration, Instant};
use tracing::{Level, instrument};

use crate::commands::{Command, Direction, Operation};
use crate::config::Config;
use crate::config::swipe::SwipeGestureDirection;
use crate::ecs::layout::{Column, LayoutStrip};
use crate::ecs::params::{ActiveDisplay, Windows};
use crate::ecs::{
    ActiveWorkspaceMarker, ManualStripOffset, MissionControlActive, Position, RepositionMarker,
    ScrollPositionHold, ScrollSnapTarget, Scrolling, SendMessageTrigger,
};
use crate::errors::Result;
use bevy::ecs::schedule::common_conditions::on_message;

use crate::events::{Event, InputEvent};
use crate::manager::{Window, WindowManager};
use crate::platform::Modifiers;
use crate::util::round_px;

pub struct ScrollEventsPlugin;

/// Upper bound on the timestep used to *advance* the strip.
///
/// `Time::<Virtual>` is deliberately given a 10s `max_delta` (see [`crate::ecs`])
/// so `elapsed()` keeps tracking wall-clock across a stalled frame — the
/// finger-lift timeout below depends on that. It is the wrong bound for
/// integration: a frame delayed by a blocking AX round trip would otherwise
/// advance the strip by `velocity * dt * viewport_width` in one step and slam
/// it into the far clamp bound. Integrate at most one 30fps frame per update,
/// however long the frame actually took.
const MAX_STEP_SECS: f64 = 1.0 / 30.0;

/// Lower bound on the timestep used to *derive* a velocity from a gesture delta.
///
/// Here the true delta is what we want — a backlog drained after a stall really
/// does represent that much finger travel over that much time. The hazard is
/// the opposite one: on a catch-up frame `dt` approaches zero, and
/// `gesture_delta / dt` diverges.
const MIN_STEP_SECS: f64 = 1.0 / 1000.0;

/// The on-screen strip, its origin, and the scroll state being applied to it.
type ScrollingStrip<'w, 's> = Single<
    'w,
    's,
    (
        &'static LayoutStrip,
        &'static mut Position,
        &'static mut Scrolling,
    ),
    (With<ActiveWorkspaceMarker>, Without<Window>),
>;

type CenteringStrip<'w, 's> = Single<
    'w,
    's,
    (
        &'static LayoutStrip,
        &'static Position,
        &'static mut Scrolling,
    ),
    (With<ActiveWorkspaceMarker>, Without<ScrollPositionHold>),
>;

impl Plugin for ScrollEventsPlugin {
    fn build(&self, app: &mut App) {
        let mission_control_inactive = |mission_control: Option<Res<MissionControlActive>>| {
            mission_control.is_none_or(|active| !active.0)
        };

        // Only the two gesture systems are gated on an input event. The rest of
        // the chain (inertia, snap force, integrator) must keep running after
        // the fingers stop sending events, since that's when they take over.
        app.add_systems(
            Update,
            (
                vertical_swipe_gesture
                    .run_if(mission_control_inactive)
                    .run_if(on_message::<InputEvent>),
                (
                    swipe_gesture
                        .run_if(mission_control_inactive)
                        .run_if(on_message::<InputEvent>),
                    apply_swipe_paging,
                    apply_flick_snap,
                    apply_inertia,
                    apply_snap_force,
                    scrolling_integrator,
                    apply_scrolling_constraints,
                    swiping_timeout,
                )
                    .chain(),
            ),
        );
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn swipe_gesture(
    mut messages: MessageReader<InputEvent>,
    active_display: ActiveDisplay,
    mut active_workspace: Single<
        (Entity, &Position, Option<&mut Scrolling>),
        With<ActiveWorkspaceMarker>,
    >,
    time: Res<Time>,
    config: Res<Config>,
    mut commands: Commands,
    mut contact: Local<bool>,
) {
    let (entity, position, scrolling) = &mut *active_workspace;
    let mut scroll = scrolling.as_deref().cloned().unwrap_or(Scrolling {
        velocity: 0.0,
        position: f64::from(position.x),
        is_user_swiping: false,
        last_event: time.elapsed(),
        contact_active: *contact,
        gesture_origin: f64::from(position.x),
        release_velocity: 0.0,
        snap_target: None,
        paging: None,
    });
    let mut changed = false;
    let mut moved = false;
    let sensitivity = config.swipe_sensitivity();
    let width = f64::from(active_display.actual_bounds(&config).width());
    let direction = swipe_direction(&config);
    // Preserve the modifier-wheel scale used by existing installations.
    let scroll_scale = 0.005 + (0.145 / 2.0) * sensitivity;
    let mut delta = 0.0;

    // Process boundaries in order, including down/move/up in a single frame.
    // Never let a new contact inherit an earlier fling or pending snap.
    for InputEvent(event) in messages.read() {
        match event {
            Event::TouchpadDown => {
                *contact = true;
                apply_gesture_delta(&mut scroll, delta, width, direction, &time);
                scroll.velocity = 0.0;
                scroll.release_velocity = 0.0;
                scroll.snap_target = None;
                scroll.paging = None;
                scroll.gesture_origin = scroll.position;
                scroll.is_user_swiping = true;
                scroll.contact_active = true;
                scroll.last_event = time.elapsed();
                delta = 0.0;
                changed |= scrolling.is_some();
            }
            Event::TouchpadUp => {
                *contact = false;
                apply_gesture_delta(&mut scroll, delta, width, direction, &time);
                delta = 0.0;
                release_gesture(&mut scroll, time.elapsed());
                changed |= scrolling.is_some() || moved;
            }
            Event::Scroll { delta: amount } if amount.is_finite() => {
                delta += amount * scroll_scale * sensitivity;
                moved = true;
            }
            Event::Swipe {
                delta: amount,
                fingers,
            } if amount.is_finite() && config.swipe_gesture_fingers() == Some(*fingers) => {
                if *fingers == 3 && config.swipe_three_finger_paging() {
                    apply_gesture_delta(&mut scroll, delta, width, direction, &time);
                    delta = 0.0;
                    apply_paging_delta(&mut scroll, *amount, width, direction, &time);
                } else {
                    delta += amount * sensitivity;
                }
                moved |= *amount != 0.0;
            }
            _ => {}
        }
    }
    apply_gesture_delta(&mut scroll, delta, width, direction, &time);
    if !changed && !moved {
        return;
    }

    if let Ok(mut entity_commands) = commands.get_entity(*entity) {
        entity_commands.try_remove::<ManualStripOffset>();
        if moved && config.preserve_scroll_until_click() {
            entity_commands.try_insert(ScrollPositionHold);
            entity_commands.try_remove::<RepositionMarker>();
        }
        if let Some(scrolling) = scrolling {
            **scrolling = scroll;
        } else if moved || changed {
            entity_commands.try_insert(scroll);
        }
    }
}

fn swipe_direction(config: &Config) -> f64 {
    match config.swipe_gesture_direction() {
        SwipeGestureDirection::Natural => -1.0,
        SwipeGestureDirection::Reversed => 1.0,
    }
}

fn apply_gesture_delta(
    scroll: &mut Scrolling,
    delta: f64,
    width: f64,
    direction: f64,
    time: &Time,
) {
    if delta == 0.0 {
        return;
    }
    scroll.paging = None;
    let fresh = !scroll.is_user_swiping;
    if fresh {
        scroll.gesture_origin = scroll.position;
        scroll.velocity = 0.0;
    }
    let dt = if fresh || scroll.last_event == time.elapsed() {
        time.delta_secs_f64()
    } else {
        time.elapsed()
            .saturating_sub(scroll.last_event)
            .as_secs_f64()
    }
    .max(MIN_STEP_SECS);
    let sample = (delta / dt).clamp(-12.0, 12.0);
    // A short time-based filter is stable across input rates. Reversing a
    // gesture must change direction immediately rather than fight old inertia.
    let alpha = 1.0 - (-dt / 0.035).exp();
    scroll.velocity = if fresh || scroll.velocity * sample <= 0.0 {
        sample
    } else {
        alpha * sample + (1.0 - alpha) * scroll.velocity
    };
    scroll.position += delta * width * direction;
    scroll.is_user_swiping = true;
    scroll.last_event = time.elapsed();
    scroll.release_velocity = 0.0;
    scroll.snap_target = None;
}

fn apply_paging_delta(scroll: &mut Scrolling, delta: f64, width: f64, direction: f64, time: &Time) {
    if delta == 0.0 {
        return;
    }
    if !scroll.is_user_swiping {
        scroll.gesture_origin = scroll.position;
        scroll.paging = None;
    }
    let paging = scroll.paging.get_or_insert_default();
    paging.displacement += delta * direction;
    paging.committed = false;
    scroll.position = scroll.gesture_origin + paging.displacement * width;
    scroll.velocity = 0.0;
    scroll.release_velocity = 0.0;
    scroll.snap_target = None;
    scroll.is_user_swiping = true;
    scroll.last_event = time.elapsed();
}

fn release_gesture(scroll: &mut Scrolling, now: Duration) {
    scroll.contact_active = false;
    if !scroll.is_user_swiping {
        return;
    }
    // Pausing before lifting is a deliberate stop, not a flick.
    if now.saturating_sub(scroll.last_event) > Duration::from_millis(100) {
        scroll.velocity = 0.0;
    }
    scroll.release_velocity = scroll.velocity;
    scroll.is_user_swiping = false;
}

#[instrument(level = Level::TRACE, skip_all)]
pub(super) fn swiping_timeout(
    strips: Populated<(Entity, &mut Scrolling), With<LayoutStrip>>,
    active_display: ActiveDisplay,
    config: Res<Config>,
    time: Res<Time>,
    window_manager: Res<WindowManager>,
    mut commands: Commands,
) {
    const FINGER_LIFT_THRESHOLD: Duration = Duration::from_millis(70);
    let viewport_width = f64::from(active_display.actual_bounds(&config).width());

    for (entity, mut scroll) in strips {
        let idle = time.elapsed().saturating_sub(scroll.last_event);
        if scroll.is_user_swiping && !scroll.contact_active && idle > FINGER_LIFT_THRESHOLD {
            release_gesture(&mut scroll, time.elapsed());
        }
        // Stop in pixels per second, not pixels per frame. The old five-pixel
        // frame cutoff discarded most of a modest flick's visible coast.
        if !scroll.is_user_swiping
            && scroll.snap_target.is_none()
            && scroll.paging.is_none_or(|paging| paging.committed)
            && scroll.velocity.abs() * viewport_width < 5.0
        {
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<Scrolling>();
            }
            if let Some(point) = window_manager.cursor_position() {
                commands.trigger(SendMessageTrigger(Event::MouseMoved {
                    point,
                    modifiers: Modifiers::empty(),
                }));
            }
        }
    }
}

/// Follow the fingers within one adjacent snap, then finish it at lift even
/// after a pause or a tiny gesture. Never coast or skip multiple destinations.
fn apply_swipe_paging(
    mut strip: ScrollingStrip,
    active_display: ActiveDisplay,
    windows: Windows,
    config: Res<Config>,
) {
    let (layout, _, ref mut scroll) = *strip;
    let Some(paging) = scroll.paging else {
        return;
    };
    if !config.swipe_three_finger_paging() {
        scroll.paging = None;
        scroll.snap_target = None;
        return;
    }
    if paging.committed {
        return;
    }
    let viewport = active_display.actual_bounds(&config);
    let width = f64::from(viewport.width());
    let target = layout
        .all_columns()
        .into_iter()
        .flat_map(|entity| [false, true].map(move |trailing| ScrollSnapTarget { entity, trailing }))
        .filter_map(|candidate| {
            let (leading, column_width, trailing_alignment) =
                snap_column_geometry(candidate.entity, &windows, &viewport, &config, true)?;
            if candidate.trailing && !trailing_alignment {
                return None;
            }
            let target = leading
                + if candidate.trailing {
                    width - column_width
                } else {
                    0.0
                };
            let target = clamp_viewport_offset(
                round_px(target),
                layout,
                &windows,
                &|e| windows.moving_frame(e),
                &viewport,
                &config,
            )
            .map_or(target, f64::from);
            let distance = (target - scroll.gesture_origin) * paging.displacement.signum();
            (paging.displacement != 0.0 && distance > 2.0).then_some((candidate, target, distance))
        })
        .min_by(|a, b| a.2.total_cmp(&b.2));
    scroll.velocity = 0.0;
    if scroll.is_user_swiping {
        let end = target.map_or(scroll.gesture_origin, |(_, target, _)| target);
        scroll.position = scroll.position.clamp(
            scroll.gesture_origin.min(end),
            scroll.gesture_origin.max(end),
        );
    } else {
        scroll.snap_target = target.map(|(candidate, _, _)| candidate);
        if target.is_none() {
            scroll.position = scroll.gesture_origin;
        }
        if let Some(ref mut paging) = scroll.paging {
            paging.committed = true;
        }
    }
}

/// Select a destination using the projected resting point, so a brisk flick
/// can finish revealing a full- or half-width window but a careful drag stays put.
fn apply_flick_snap(
    mut strip: ScrollingStrip,
    active_display: ActiveDisplay,
    windows: Windows,
    config: Res<Config>,
    time: Res<Time>,
) {
    let (layout, _, ref mut scroll) = *strip;
    if scroll.is_user_swiping {
        return;
    }
    let threshold = config.swipe_snap_speed();
    let momentum = config.swipe_momentum();
    let paging = scroll.paging.is_some();
    if !paging && (threshold == 0.0 || momentum == 0.0) {
        scroll.snap_target = None;
        return;
    }
    let viewport = active_display.actual_bounds(&config);
    let width = f64::from(viewport.width());
    let direction = swipe_direction(&config);
    let projected = scroll.position
        + scroll.velocity * direction * width * momentum / config.swipe_deceleration();
    let column_geometry =
        |entity| snap_column_geometry(entity, &windows, &viewport, &config, paging);
    if !paging && scroll.snap_target.is_none() {
        let physical_direction = scroll.release_velocity * direction;
        scroll.snap_target = layout
            .all_columns()
            .into_iter()
            .flat_map(|entity| {
                [false, true].map(move |trailing| ScrollSnapTarget { entity, trailing })
            })
            .filter_map(|candidate| {
                let (leading, column_width, trailing_alignment) =
                    column_geometry(candidate.entity)?;
                if candidate.trailing && !trailing_alignment {
                    return None;
                }
                let target = leading
                    + if candidate.trailing {
                        width - column_width
                    } else {
                        0.0
                    };
                let returning = config.swipe_snap_back()
                    && (target - scroll.gesture_origin).abs() <= 2.0
                    && (projected - target).abs() < width * config.swipe_snap_exit_distance();
                let advancing = scroll.release_velocity.abs() >= threshold
                    && flick_target_qualifies(
                        target,
                        scroll.gesture_origin,
                        projected,
                        physical_direction,
                        column_width,
                        config.swipe_snap_visible(),
                    )
                    && (config.swipe_snap_back()
                        || (target - scroll.position) * physical_direction.signum() > 0.5);
                (returning || advancing).then_some((candidate, (target - projected).abs()))
            })
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .map(|(candidate, _)| candidate);
    }
    let Some(candidate) = scroll.snap_target else {
        return;
    };
    let Some((leading, column_width, trailing_alignment)) =
        column_geometry(candidate.entity).filter(|_| layout.index_of(candidate.entity).is_ok())
    else {
        scroll.snap_target = None;
        scroll.release_velocity = 0.0;
        return;
    };
    if candidate.trailing && !trailing_alignment {
        scroll.snap_target = None;
        scroll.release_velocity = 0.0;
        return;
    }
    let target = leading
        + if candidate.trailing {
            width - column_width
        } else {
            0.0
        };
    let target = clamp_viewport_offset(
        round_px(target),
        layout,
        &windows,
        &|e| windows.moving_frame(e),
        &viewport,
        &config,
    )
    .map_or(target, f64::from);
    advance_snap_animation(
        scroll,
        target,
        width,
        direction,
        config.swipe_snap_animation(),
        time.delta_secs_f64().min(MAX_STEP_SECS),
    );
}

fn snap_column_geometry(
    entity: Entity,
    windows: &Windows,
    viewport: &IRect,
    config: &Config,
    paging: bool,
) -> Option<(f64, f64, bool)> {
    let frame = windows.moving_frame(entity)?;
    let x = windows.layout_position(entity)?.x;
    let width = f64::from(viewport.width());
    let column_width = f64::from(frame.width());
    let leading = f64::from(viewport.min.x - x);
    // Layout slots include the gap. Native fullscreen is never a column.
    if paging {
        // Apps can enforce widths between presets (for example Tailscale's
        // minimum width). Every column must remain reachable by paging, with
        // both edges available for narrower and oversized windows. Ignore
        // pixel-rounding differences so full-width columns keep a single stop.
        return Some((leading, column_width, (column_width - width).abs() > 2.0));
    }
    let full =
        config.swipe_snap_full_width() && (width * 0.9..=width * 1.02).contains(&column_width);
    let half =
        config.swipe_snap_half_width() && (width * 0.45..=width * 0.55).contains(&column_width);
    (full || half).then_some((leading, column_width, half))
}

fn advance_snap_animation(
    scroll: &mut Scrolling,
    target: f64,
    width: f64,
    direction: f64,
    speed: f64,
    dt: f64,
) {
    let distance = target - scroll.position;
    // Exact critically damped spring step, starting at the release velocity.
    // This keeps the transition into snapping continuous, with no sudden jump
    // to a fixed animation speed. Clamp crossings so the window never bounces.
    let omega = 12.0 * speed;
    let velocity = scroll.velocity * direction * width;
    let displacement = scroll.position - target;
    let c = velocity + omega * displacement;
    let decay = (-omega * dt).exp();
    scroll.position = target + (displacement + c * dt) * decay;
    scroll.velocity = (velocity - omega * c * dt) * decay / (direction * width);
    if (target - scroll.position) * distance < 0.0 {
        scroll.position = target;
    }
    if (scroll.position - target).abs() <= 0.5 {
        scroll.position = target;
        scroll.velocity = 0.0;
        scroll.release_velocity = 0.0;
        scroll.snap_target = None;
    }
}

fn flick_target_qualifies(
    target: f64,
    origin: f64,
    projected: f64,
    direction: f64,
    width: f64,
    visible: f64,
) -> bool {
    // A flick can finish a nearby column but cannot pull behind its start.
    (target - origin) * direction.signum() > 0.5
        && (target - projected).abs() <= width * (1.0 - visible)
}

#[instrument(level = Level::TRACE, skip_all)]
fn apply_inertia(
    mut strips: Populated<(Entity, &mut Scrolling), With<LayoutStrip>>,
    time: Res<Time>,
    config: Res<Config>,
) {
    let dt = time.delta_secs_f64();
    for (_, mut scroll) in &mut strips {
        if scroll.is_user_swiping || scroll.snap_target.is_some() {
            continue;
        }

        if scroll.velocity.abs() > 0.001 {
            // Unbounded on purpose: decay is monotonic toward zero, so a long
            // frame can only shed more momentum, never overshoot. After a stall
            // that is what we want.
            let momentum = config.swipe_momentum();
            scroll.velocity = if momentum == 0.0 {
                0.0
            } else {
                scroll.velocity * (-config.swipe_deceleration() * dt / momentum).exp()
            };
        } else {
            scroll.velocity = 0.0;
        }
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn apply_snap_force(
    mut strip: CenteringStrip,
    active_display: ActiveDisplay,
    windows: Windows,
    config: Res<Config>,
    time: Res<Time>,
) {
    const CENTER_MAGNETIC_FORCE: f64 = 10.0;
    const SNAP_DISPLAY_RATIO: f64 = 0.45;

    if !config.auto_center() {
        return;
    }

    let viewport = active_display.actual_bounds(&config);
    let viewport_center = viewport.center().x;
    let snap_threshold = SNAP_DISPLAY_RATIO * f64::from(viewport.width());

    let (strip, position, ref mut scroll) = *strip;
    if scroll.is_user_swiping
        || scroll.snap_target.is_some()
        || scroll.paging.is_some()
        || scroll.velocity.abs() > 0.5
    {
        return;
    }

    let target_offset = strip
        .all_columns()
        .into_iter()
        .filter_map(|entity| {
            windows
                .layout_position(entity)
                .map(|p| p.0.x)
                .zip(Some(entity))
        })
        .map(|(position, entity)| {
            let col_width = windows.moving_frame(entity).map_or(0, |f| f.width());
            viewport_center - (position + col_width / 2)
        })
        .min_by_key(|target| (position.x - target).abs())
        .unwrap_or(position.x);

    let dist_to_snap = f64::from(position.x - target_offset);
    if dist_to_snap.abs() < snap_threshold {
        // This is an exponential approach, and it only pulls *toward* the
        // target while the factor stays under 1. Past that it overshoots to the
        // far side; at a 10s delta it would fling the strip 100x the distance
        // the wrong way. Clamping the factor rather than `dt` keeps that true
        // for any timestep and any `CENTER_MAGNETIC_FORCE`.
        let approach = (time.delta_secs_f64() * CENTER_MAGNETIC_FORCE).min(1.0);
        scroll.position -= dist_to_snap * approach;
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn scrolling_integrator(
    mut strip: Single<&mut Scrolling, (With<LayoutStrip>, With<ActiveWorkspaceMarker>)>,
    time: Res<Time>,
    active_display: ActiveDisplay,
    config: Res<Config>,
) {
    let dt = time.delta_secs_f64().min(MAX_STEP_SECS);
    let viewport = active_display.actual_bounds(&config);
    let viewport_width = f64::from(viewport.width());

    // Direction modifier: Natural moves strip left (negative offset) for positive delta (finger left)
    let direction_modifier = match config.swipe_gesture_direction() {
        SwipeGestureDirection::Natural => -1.0,
        SwipeGestureDirection::Reversed => 1.0,
    };

    let scroll = &mut *strip;
    if !scroll.is_user_swiping && scroll.snap_target.is_none() && scroll.velocity.abs() > 0.0001 {
        scroll.position += scroll.velocity * dt * viewport_width * direction_modifier;
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn apply_scrolling_constraints(
    mut strip: ScrollingStrip,
    active_display: ActiveDisplay,
    windows: Windows,
    config: Res<Config>,
) {
    let viewport = active_display.actual_bounds(&config);
    let (strip, ref mut position, ref mut scroll) = *strip;

    let get_window_frame = |entity| windows.moving_frame(entity);
    if let Some(clamped_offset) = clamp_viewport_offset(
        round_px(scroll.position),
        strip,
        &windows,
        &get_window_frame,
        &viewport,
        &config,
    ) {
        position.x = clamped_offset;
        // Keep subpixel precision while coasting; round only the native frame.
        // Stop outward velocity at the boundary instead of burning idle frames.
        if clamped_offset != round_px(scroll.position) {
            scroll.position = f64::from(clamped_offset);
            scroll.velocity = 0.0;
            scroll.snap_target = None;
        }
    } else {
        scroll.velocity = 0.0;
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn clamp_viewport_offset<W>(
    current_offset: i32,
    layout_strip: &LayoutStrip,
    windows: &Windows,
    get_window_frame: &W,
    viewport: &IRect,
    config: &Config,
) -> Option<i32>
where
    W: Fn(Entity) -> Option<IRect>,
{
    let total_strip_width = layout_strip
        .last()
        .ok()
        .and_then(|column| column.top())
        .and_then(|entity| {
            windows
                .layout_position(entity)
                .zip(get_window_frame(entity))
        })
        .map(|(position, frame)| position.x + frame.width())?;

    let continuous_swipe = config.continuous_swipe();
    let strip_position = |column: Result<Column>| {
        column
            .ok()
            .and_then(|column| column.top())
            .and_then(|entity| windows.layout_position(entity))
            .map(|position| position.0.x)
    };

    let left_snap = strip_position(layout_strip.last());
    let right_snap = strip_position(layout_strip.first());

    Some(
        if continuous_swipe && let Some((left_snap, right_snap)) = left_snap.zip(right_snap) {
            // Allow to scroll away until the last or first window snaps.
            current_offset.clamp(viewport.min.x - left_snap, viewport.max.x - right_snap)
        } else if viewport.width() < total_strip_width {
            // Snap the strip directly to the edges.
            current_offset.clamp(viewport.max.x - total_strip_width, viewport.min.x)
        } else {
            // Snap the strip directly to the edges.
            current_offset.clamp(viewport.min.x, viewport.max.x - total_strip_width)
        },
    )
}

#[derive(Default)]
struct VerticalGestureState {
    accumulated: f64,
    last_event: Option<Instant>,
    fired: bool,
}

#[instrument(level = Level::TRACE, skip_all)]
fn vertical_swipe_gesture(
    mut messages: MessageReader<InputEvent>,
    active_display: ActiveDisplay,
    config: Res<Config>,
    mut commands: Commands,
    mut state: Local<VerticalGestureState>,
) {
    const GESTURE_TIMEOUT: Duration = Duration::from_millis(150);

    if active_display.fullscreen().is_some() {
        return;
    }

    // Reset state when the gesture times out (fingers lifted).
    if let Some(last) = state.last_event
        && last.elapsed() > GESTURE_TIMEOUT
    {
        state.accumulated = 0.0;
        state.fired = false;
    }

    for InputEvent(event) in messages.read() {
        match event {
            Event::VerticalScrollTick { delta } => {
                switch_virtual_workspace(*delta, &config, &mut commands);
            }
            Event::VerticalSwipe { delta, fingers }
                if config
                    .swipe_gesture_fingers()
                    .is_some_and(|fingers_configured| fingers_configured == *fingers) =>
            {
                state.last_event = Some(Instant::now());

                if !state.fired {
                    state.accumulated += delta;
                }
            }
            _ => {}
        }
    }

    // Threshold needs to be high enough that incidental vertical movement
    // during horizontal swipes doesn't trigger a workspace switch.
    let threshold = 0.15 / config.swipe_sensitivity();
    if state.accumulated.abs() >= threshold {
        switch_virtual_workspace(state.accumulated, &config, &mut commands);
        state.accumulated = 0.0;
        state.fired = true;
    }
}

fn switch_virtual_workspace(delta: f64, config: &Config, commands: &mut Commands) {
    let physical_finger_direction = if delta > 0.0 {
        Direction::South
    } else {
        Direction::North
    };
    let direction = match config.swipe_gesture_direction() {
        SwipeGestureDirection::Natural => physical_finger_direction.reverse(),
        SwipeGestureDirection::Reversed => physical_finger_direction,
    };
    commands.trigger(SendMessageTrigger(Event::Command {
        command: Command::Window(Operation::Virtual(direction)),
    }));
}
