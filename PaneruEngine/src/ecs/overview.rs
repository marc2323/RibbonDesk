//! Companion overview commands, addressed by window ID rather than changing focus.
use bevy::prelude::*;
use tracing::{Level, instrument, warn};

use super::focus::{FocusWindow, VERIFY_FOCUS_TIMEOUT};
use super::layout::LayoutStrip;
use super::params::Windows;
use super::{
    ActiveWorkspaceMarker, EnsureVisibleMarker, FocusedMarker, Position, RepositionMarker,
    ScrollPositionHold, Scrolling, SpawnCommandsExt, Timeout, VerifyFocus,
};
use crate::events::Event;
use crate::manager::{Application, Window};
use crate::types::commands::{Command, OverviewCommand};

#[derive(Resource, Default)]
pub(crate) struct OverviewActive(pub bool, Option<i32>);

/// Keep input suspended and member windows snapping until the companion has
/// covered the native focus/position handoff and explicitly releases it.
#[derive(Component)]
pub(crate) struct OverviewHandoff {
    pub strip: Entity,
}
#[derive(Component)]
pub(crate) struct OverviewReady;

#[derive(Event)]
struct RequestWindowAction {
    id: i32,
    quit_app: bool,
}

pub(crate) fn inactive(overview: Option<Res<OverviewActive>>) -> bool {
    overview.is_none_or(|state| !state.0)
}

pub(crate) fn register(app: &mut App) {
    app.init_resource::<OverviewActive>()
        .add_observer(request_window_action)
        .add_systems(
            PreUpdate,
            (
                handle_commands.before(crate::commands::query::state_query_handler),
                forward_pan,
            )
                .chain()
                .after(super::systems::pump_events)
                .run_if(on_message::<Event>),
        )
        .add_systems(
            PostUpdate,
            acknowledge_handoff
                .after(super::systems::commit_window_position)
                .after(super::systems::verify_window_position)
                .after(super::systems::commit_window_size),
        );
}

// The native event tap uses this mirror before queuing mouse/keyboard events.
// Tests use the resource only, so parallel harnesses never share state.
#[cfg(not(test))]
static OWNER: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);

pub(crate) fn input_is_active() -> bool {
    #[cfg(not(test))]
    {
        let pid = OWNER.load(std::sync::atomic::Ordering::Relaxed);
        pid > 0 && unsafe { libc::kill(pid, 0) } == 0
    }
    #[cfg(test)]
    {
        false
    }
}

fn set_active(state: &mut OverviewActive, active: bool) {
    state.0 = active;
    #[cfg(not(test))]
    OWNER.store(
        if active { state.1.unwrap_or(0) } else { 0 },
        std::sync::atomic::Ordering::Relaxed,
    );
}

fn notify(name: &str) {
    #[cfg(not(test))]
    {
        use objc2_foundation::{NSDistributedNotificationCenter, NSString};
        let name = NSString::from_str(name);
        // No payload or window metadata leaves the engine in this notification.
        unsafe {
            NSDistributedNotificationCenter::defaultCenter()
                .postNotificationName_object_userInfo_deliverImmediately(&name, None, None, true);
        }
    }
    #[cfg(test)]
    let _ = name;
}

fn notify_ready(id: i32) {
    notify_value("local.paneru.overview.ready", &id.to_string());
}

fn notify_value(name: &str, value: &str) {
    #[cfg(not(test))]
    {
        use objc2_foundation::{NSDistributedNotificationCenter, NSString};
        let name = NSString::from_str(name);
        let object = NSString::from_str(value);
        unsafe {
            NSDistributedNotificationCenter::defaultCenter()
                .postNotificationName_object_userInfo_deliverImmediately(
                    &name,
                    Some(&object),
                    None,
                    true,
                );
        }
    }
    #[cfg(test)]
    let _ = (name, value);
}

#[allow(clippy::type_complexity)]
fn acknowledge_handoff(
    pending: Populated<(Entity, &OverviewHandoff), Without<OverviewReady>>,
    strips: Query<(&LayoutStrip, Has<RepositionMarker>)>,
    mut windows: Query<(
        &mut Window,
        &Position,
        &ChildOf,
        Has<RepositionMarker>,
        Has<EnsureVisibleMarker>,
        Has<FocusedMarker>,
    )>,
    apps: Query<&Application>,
    mut commands: Commands,
    _main_thread: Option<NonSend<crate::overlay::OverlayManager>>,
) {
    for (entity, pending) in &pending {
        let Ok((strip, moving)) = strips.get(pending.strip) else {
            continue;
        };
        if moving
            || strip.all_windows().iter().any(|member| {
                windows
                    .get(*member)
                    .is_ok_and(|(_, _, _, moving, reveal, _)| moving || reveal)
            })
        {
            continue;
        }
        let Ok((mut window, position, parent, _, _, focused)) = windows.get_mut(entity) else {
            continue;
        };
        // Process the OS focus event under overview ownership before releasing
        // the panel, so its later auto-center pass cannot move the revealed strip.
        if !focused {
            continue;
        }
        let Ok(app) = apps.get(parent.parent()) else {
            continue;
        };
        if !app.is_frontmost() || app.focused_window_id().ok() != Some(window.id()) {
            continue;
        }
        // Read back native geometry, not just the ECS target or an IPC receipt.
        if !window
            .update_frame()
            .is_ok_and(|frame| frame.min.chebyshev_distance(position.0) <= 2)
        {
            continue;
        }
        commands.entity(entity).insert(OverviewReady);
        notify_ready(window.id());
    }
}

fn clear_handoffs(handoffs: &Query<Entity, With<OverviewHandoff>>, commands: &mut Commands) {
    for entity in handoffs {
        commands
            .entity(entity)
            .remove::<(OverviewHandoff, OverviewReady)>();
    }
}

fn request_native_focus(entity: Entity, commands: &mut Commands) {
    commands.entity(entity).insert((
        VerifyFocus,
        Timeout::for_component::<VerifyFocus>(VERIFY_FOCUS_TIMEOUT),
    ));
    commands.trigger(FocusWindow {
        entity,
        raise: true,
    });
}

fn closes_overview(event: &Event) -> bool {
    matches!(
        event,
        Event::SpaceChanged
            | Event::Exit
            | Event::MissionControlShowAllWindows
            | Event::MissionControlShowFrontWindows
            | Event::MissionControlShowDesktop
    )
}

#[instrument(level = Level::DEBUG, skip_all)]
fn handle_commands(
    mut events: MessageReader<Event>,
    mut state: ResMut<OverviewActive>,
    windows: Windows,
    mut strips: Query<(Entity, &mut LayoutStrip), With<ActiveWorkspaceMarker>>,
    handoffs: Query<Entity, With<OverviewHandoff>>,
    mut commands: Commands,
    // Native notifications must stay on the main thread.
    _main_thread: Option<NonSend<crate::overlay::OverlayManager>>,
) {
    #[cfg(not(test))]
    if state.0 && !input_is_active() {
        set_active(&mut state, false);
        clear_handoffs(&handoffs, &mut commands);
        notify("local.paneru.overview.close");
    }
    for event in events.read() {
        if closes_overview(event) {
            if state.0 {
                set_active(&mut state, false);
                clear_handoffs(&handoffs, &mut commands);
                notify("local.paneru.overview.close");
            }
            continue;
        }
        let Event::Command {
            command: Command::Overview(action),
        } = event
        else {
            continue;
        };
        match action {
            OverviewCommand::Show => {
                if !strips.is_empty() {
                    notify("local.paneru.overview.show");
                }
            }
            OverviewCommand::Dismiss => {
                if state.0 {
                    notify("local.paneru.overview.close");
                }
            }
            OverviewCommand::Accept => {
                if state.0 {
                    notify("local.paneru.overview.accept");
                }
            }
            OverviewCommand::Begin(pid) => {
                if strips.is_empty() {
                    continue;
                }
                state.1 = Some(*pid);
                clear_handoffs(&handoffs, &mut commands);
                set_active(&mut state, true);
                for (entity, _) in &strips {
                    commands.entity(entity).remove::<Scrolling>();
                }
            }
            OverviewCommand::End => {
                set_active(&mut state, false);
                clear_handoffs(&handoffs, &mut commands);
                // This is the companion's release acknowledgment. Echoing a
                // close notification can dismiss a freshly reopened overview.
            }
            OverviewCommand::Focus(id) => {
                let Some((_, entity)) = windows.find(*id) else {
                    continue;
                };
                let Some((strip_entity, _)) =
                    strips.iter().find(|(_, strip)| strip.contains(entity))
                else {
                    continue;
                };
                clear_handoffs(&handoffs, &mut commands);
                if state.0 {
                    commands.entity(entity).insert(OverviewHandoff {
                        strip: strip_entity,
                    });
                }
                commands
                    .entity(strip_entity)
                    .remove::<(ScrollPositionHold, Scrolling, RepositionMarker)>();
                commands.ensure_visible_snap(entity, true);
                request_native_focus(entity, &mut commands);
            }
            OverviewCommand::Close(id) | OverviewCommand::QuitApp(id) => {
                if state.0 {
                    commands.trigger(RequestWindowAction {
                        id: *id,
                        quit_app: matches!(action, OverviewCommand::QuitApp(_)),
                    });
                }
            }
            OverviewCommand::Move {
                window,
                target,
                after,
            } => {
                let (Some((_, source)), Some((_, destination))) =
                    (windows.find(*window), windows.find(*target))
                else {
                    continue;
                };
                for (_, mut strip) in &mut strips {
                    if strip.move_beside(source, destination, *after) {
                        // Keep the viewport anchored while the overview stays open.
                        commands.reshuffle_around(source);
                        break;
                    }
                }
            }
        }
    }
}

/// Forward one camera delta per event batch, retaining native input ownership.
fn forward_pan(
    mut events: MessageReader<Event>,
    state: Res<OverviewActive>,
    _main_thread: Option<NonSend<crate::overlay::OverlayManager>>,
) {
    if !state.0 {
        events.clear();
        return;
    }
    forward_pan_updates(events.read(), |value| {
        notify_value("local.paneru.overview.pan", value);
    });
}

/// Coalesce movement while preserving down/move/up ordering within a batch.
fn forward_pan_updates<'a>(events: impl Iterator<Item = &'a Event>, mut send: impl FnMut(&str)) {
    let mut pan = 0.0;
    for event in events {
        match event {
            Event::OverviewPan { delta } if delta.is_finite() => pan += delta,
            Event::OverviewPanBegin | Event::OverviewPanEnd { .. } => {
                flush_pan(&mut pan, &mut send);
                send(match event {
                    Event::OverviewPanBegin => "begin",
                    Event::OverviewPanEnd { cancelled: true } => "cancel",
                    _ => "end",
                });
            }
            _ => {}
        }
    }
    flush_pan(&mut pan, &mut send);
}

fn flush_pan(pan: &mut f64, send: &mut impl FnMut(&str)) {
    if pan.is_finite() && *pan != 0.0 {
        send(&pan.to_string());
    }
    *pan = 0.0;
}

#[instrument(level = Level::DEBUG, skip_all)]
fn request_window_action(
    request: On<RequestWindowAction>,
    state: Res<OverviewActive>,
    windows: Windows,
    strips: Query<&LayoutStrip, With<ActiveWorkspaceMarker>>,
    apps: Query<&Application>,
    _main_thread: Option<NonSend<crate::overlay::OverlayManager>>,
) {
    // A stale preview or a command outside overview must never act on
    // another workspace or the currently focused native window.
    if !state.0 {
        return;
    }
    let Some((window, entity, parent)) = windows.find_parent(request.id) else {
        return;
    };
    if !strips.iter().any(|strip| strip.contains(entity)) {
        return;
    }
    if !request.quit_app {
        if let Err(error) = window.request_close() {
            warn!(window = request.id, %error, "Native window close request failed");
        }
    } else if let Ok(app) = apps.get(parent)
        && !app.request_quit()
    {
        warn!(window = request.id, "Application declined the quit request");
    }
    // Native destroy/quit notifications own removal. Leave windows and
    // input ownership intact when an app needs to show save/cancel UI.
}

#[cfg(test)]
mod pan_tests {
    use super::*;

    #[test]
    fn contact_boundaries_preserve_the_last_delta_before_release_and_cancel() {
        let events = [
            Event::OverviewPanBegin,
            Event::OverviewPan { delta: 0.25 },
            Event::OverviewPan { delta: 0.5 },
            Event::OverviewPanEnd { cancelled: false },
            Event::OverviewPanBegin,
            Event::OverviewPan { delta: -0.25 },
            Event::OverviewPanEnd { cancelled: true },
        ];
        let mut updates = Vec::new();
        forward_pan_updates(events.iter(), |value| updates.push(value.to_owned()));
        assert_eq!(
            updates,
            ["begin", "0.75", "end", "begin", "-0.25", "cancel"]
        );
    }

    #[test]
    fn invalid_and_zero_deltas_cannot_start_a_coast() {
        let events = [
            Event::OverviewPanBegin,
            Event::OverviewPan { delta: f64::NAN },
            Event::OverviewPan {
                delta: f64::INFINITY,
            },
            Event::OverviewPan { delta: 0.0 },
            Event::OverviewPanEnd { cancelled: false },
        ];
        let mut updates = Vec::new();
        forward_pan_updates(events.iter(), |value| updates.push(value.to_owned()));
        assert_eq!(updates, ["begin", "end"]);
    }
}
