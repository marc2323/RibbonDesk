use bevy::ecs::change_detection::{DetectChanges, DetectChangesMut};
use bevy::ecs::entity::Entity;
use bevy::ecs::lifecycle::RemovedComponents;
use bevy::ecs::message::MessageReader;
use bevy::ecs::query::{Added, Changed, Or, With};
use bevy::ecs::resource::Resource;
use bevy::ecs::system::{In, Local, Query, Res, ResMut, SystemParam};
use bevy::math::IRect;
use bevy::time::Time;
use objc2_foundation::NSRect;
use std::time::Duration;

use super::{
    ActiveWorkspaceMarker, Bounds, FocusedMarker, MissionControlActive, NativeFullscreenMarker,
    Position, RepositionMarker, ResizeMarker, Scrolling, SystemTheme,
};
use crate::config::Config;
use crate::ecs::layout::LayoutStrip;
use crate::events::Event;
use crate::manager::{Display, Window};
use crate::overlay::BorderParams;

/// Desired presentation, independently testable with the mock window manager.
#[derive(Resource, Debug, Default, PartialEq)]
pub(crate) enum OverlayState {
    #[default]
    Hidden,
    Disabled,
    Visible {
        frame: NSRect,
        dim_opacity: f32,
        dim_color: (f64, f64, f64),
        border: Option<BorderParams>,
    },
}

pub(crate) fn set_overlay_state(In(next): In<OverlayState>, mut state: ResMut<OverlayState>) {
    state.set_if_neq(next);
}

/// A single quiet-period deadline, checked by the existing event loop. It does
/// not keep the frame pump active or add a polling timer.
#[derive(Resource, Default, PartialEq)]
pub(crate) struct OverlayMotion {
    settle_at: Option<Duration>,
}

impl OverlayMotion {
    pub(crate) fn is_settling(&self) -> bool {
        self.settle_at.is_some()
    }
}

type MotionMarkers<'w, 's> = Query<
    'w,
    's,
    (),
    (
        Or<(With<FocusedMarker>, With<ActiveWorkspaceMarker>)>,
        Or<(With<RepositionMarker>, With<ResizeMarker>, With<Scrolling>)>,
    ),
>;

/// Reads only cached ECS geometry; native window queries belong to the settled
/// presentation system.
pub(crate) fn track_overlay_motion(
    config: Option<Res<Config>>,
    motion: MotionMarkers,
    geometry: Query<(Entity, &Window), With<FocusedMarker>>,
    time: Res<Time>,
    mut settling: ResMut<OverlayMotion>,
    mut previous_geometry: Local<Option<(Entity, IRect)>>,
) {
    const SETTLE_DELAY: Duration = Duration::from_millis(150);

    let geometry = geometry
        .iter()
        .next()
        .map(|(entity, window)| (entity, window.frame()));
    let moved = geometry.zip(*previous_geometry).is_some_and(
        |((entity, frame), (previous_entity, previous_frame))| {
            entity == previous_entity && frame != previous_frame
        },
    );
    *previous_geometry = geometry;

    let enabled = config
        .is_some_and(|config| config.has_dim_inactive_color() || config.border_active_window());
    let settle_at = if !enabled {
        None
    } else if moved || !motion.is_empty() {
        Some(time.elapsed() + SETTLE_DELAY)
    } else {
        settling
            .settle_at
            .filter(|deadline| time.elapsed() < *deadline)
    };
    settling.set_if_neq(OverlayMotion { settle_at });
}

type WorkspaceChanges<'w, 's> = Query<
    'w,
    's,
    (),
    (
        With<ActiveWorkspaceMarker>,
        Or<(
            Changed<LayoutStrip>,
            Added<ActiveWorkspaceMarker>,
            Added<Scrolling>,
            Added<NativeFullscreenMarker>,
        )>,
    ),
>;
type FocusChanges<'w, 's> = Query<
    'w,
    's,
    (),
    (
        With<FocusedMarker>,
        Or<(
            Added<FocusedMarker>,
            Changed<Position>,
            Changed<Bounds>,
            Changed<Window>,
            Added<NativeFullscreenMarker>,
        )>,
    ),
>;

pub(crate) fn overlay_motion_dirty(
    config: Option<Res<Config>>,
    focused: FocusChanges,
    motion: MotionMarkers,
    settling: Res<OverlayMotion>,
) -> bool {
    config.is_some_and(|config| {
        config.is_changed()
            || ((config.has_dim_inactive_color() || config.border_active_window())
                && (!focused.is_empty() || !motion.is_empty() || settling.is_settling()))
    })
}

/// Cheap ECS change filters only: no AX reads, timers, or `AppKit` work at idle.
#[derive(SystemParam)]
pub(crate) struct OverlayChanges<'w, 's> {
    config: Option<Res<'w, Config>>,
    mission_control: Res<'w, MissionControlActive>,
    theme: Option<Res<'w, SystemTheme>>,
    workspaces: WorkspaceChanges<'w, 's>,
    focused: FocusChanges<'w, 's>,
    displays: Query<'w, 's, (), Changed<Display>>,
    focus_lost: RemovedComponents<'w, 's, FocusedMarker>,
    workspace_lost: RemovedComponents<'w, 's, ActiveWorkspaceMarker>,
    scrolling_ended: RemovedComponents<'w, 's, Scrolling>,
    fullscreen_ended: RemovedComponents<'w, 's, NativeFullscreenMarker>,
    events: MessageReader<'w, 's, Event>,
    settling: Res<'w, OverlayMotion>,
    state: Res<'w, OverlayState>,
}

pub(crate) fn overlay_dirty(mut changes: OverlayChanges) -> bool {
    // Drain every stream even when another input is dirty, avoiding extra
    // redraws from removal events left behind by short-circuit evaluation.
    let removed = changes.focus_lost.read().count()
        + changes.workspace_lost.read().count()
        + changes.scrolling_ended.read().count()
        + changes.fullscreen_ended.read().count();
    let mut front_changed = false;
    for event in changes.events.read() {
        front_changed |= matches!(
            event,
            Event::ApplicationFrontSwitched { .. } | Event::SpaceChanged
        );
    }
    let Some(config) = changes.config.as_ref() else {
        return false;
    };
    if !config.has_dim_inactive_color() && !config.border_active_window() {
        return config.is_changed();
    }

    if changes.settling.is_settling() {
        // Hide once at motion start. Geometry and focus may keep changing, but
        // no native metadata reads or overlay rendering run while hidden.
        return *changes.state != OverlayState::Hidden;
    }

    changes.settling.is_changed()
        || config.is_changed()
        || changes.mission_control.is_changed()
        || changes
            .theme
            .as_ref()
            .is_some_and(DetectChanges::is_changed)
        || !changes.workspaces.is_empty()
        || !changes.focused.is_empty()
        || !changes.displays.is_empty()
        || removed > 0
        || front_changed
}

#[cfg(test)]
mod tests {
    use bevy::prelude::*;

    use super::*;
    use crate::config::MainOptions;
    use crate::events::Event;
    use crate::manager::{Origin, Size};

    #[derive(Resource, Default)]
    struct Updates(usize);

    fn config(enabled: bool) -> Config {
        (
            MainOptions {
                border_active_window: Some(enabled),
                ..Default::default()
            },
            vec![],
        )
            .into()
    }

    fn app() -> App {
        let mut app = App::new();
        app.add_plugins(MinimalPlugins)
            .add_message::<Event>()
            .insert_resource(config(true))
            .insert_resource(MissionControlActive(false))
            .init_resource::<OverlayMotion>()
            .init_resource::<OverlayState>()
            .init_resource::<Updates>()
            .add_systems(
                Update,
                (
                    track_overlay_motion.run_if(overlay_motion_dirty),
                    (|mut count: ResMut<Updates>| count.0 += 1).run_if(overlay_dirty),
                )
                    .chain(),
            );
        app.update();
        app
    }

    fn assert_one_update(app: &mut App) {
        let before = app.world().resource::<Updates>().0;
        app.update();
        assert_eq!(app.world().resource::<Updates>().0, before + 1);
        app.update();
        assert_eq!(
            app.world().resource::<Updates>().0,
            before + 1,
            "changes must be consumed"
        );
    }

    #[test]
    fn idle_frames_do_not_schedule_overlay_work() {
        let mut app = app();
        for _ in 0..500 {
            app.update();
        }
        assert_eq!(app.world().resource::<Updates>().0, 1);
    }

    #[test]
    fn focus_move_resize_and_loss_each_refresh_once() {
        let mut app = app();
        let entity = app
            .world_mut()
            .spawn((
                FocusedMarker,
                Position(Origin::ZERO),
                Bounds(Size::new(400, 300)),
            ))
            .id();
        assert_one_update(&mut app);
        app.world_mut()
            .entity_mut(entity)
            .insert(Position(Origin::new(50, 100)));
        assert_one_update(&mut app);
        app.world_mut()
            .entity_mut(entity)
            .insert(Bounds(Size::new(500, 300)));
        assert_one_update(&mut app);
        app.world_mut().entity_mut(entity).remove::<FocusedMarker>();
        assert_one_update(&mut app);
    }

    #[test]
    fn disabling_and_reenabling_still_refreshes_without_a_layout_change() {
        let mut app = app();
        app.world_mut().insert_resource(config(false));
        assert_one_update(&mut app);
        app.world_mut().insert_resource(config(true));
        assert_one_update(&mut app);
        app.world_mut().insert_resource(config(true)); // also covers a color-only config reload
        assert_one_update(&mut app);
    }

    #[test]
    fn mission_control_and_workspace_loss_refresh_without_focus_motion() {
        let mut app = app();
        app.world_mut().resource_mut::<MissionControlActive>().0 = true;
        assert_one_update(&mut app);
        app.world_mut().resource_mut::<MissionControlActive>().0 = false;
        assert_one_update(&mut app);
        let workspace = app.world_mut().spawn(ActiveWorkspaceMarker).id();
        assert_one_update(&mut app);
        app.world_mut()
            .entity_mut(workspace)
            .remove::<ActiveWorkspaceMarker>();
        assert_one_update(&mut app);
    }
}
