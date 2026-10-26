use super::*;
use crate::assert_focused;
use crate::commands::{Command, Direction, Operation};
use crate::ecs::layout::LayoutStrip;
use crate::ecs::overview::{OverviewActive, OverviewHandoff, OverviewReady};
use crate::ecs::{ActiveWorkspaceMarker, RepositionMarker, ScrollPositionHold, Scrolling};
use crate::events::Event;
use crate::manager::Window;
use crate::types::commands::OverviewCommand;
use bevy::prelude::*;

fn overview(action: OverviewCommand) -> Event {
    Event::Command {
        command: Command::Overview(action),
    }
}
fn order(world: &mut World) -> Vec<i32> {
    let mut strips = world.query_filtered::<&LayoutStrip, With<ActiveWorkspaceMarker>>();
    strips
        .single(world)
        .unwrap()
        .all_windows()
        .into_iter()
        .map(|entity| world.get::<Window>(entity).unwrap().id())
        .collect()
}

#[test]
fn overview_inserts_in_both_directions_without_swapping_intervening_windows() {
    TestHarness::new()
        .with_windows(5)
        .on_iteration(1, |world, _| assert_eq!(order(world), vec![0, 4, 1, 2, 3]))
        .on_iteration(2, |world, _| assert_eq!(order(world), vec![0, 1, 2, 3, 4]))
        .on_iteration(3, |world, _| assert_eq!(order(world), vec![0, 1, 2, 3, 4]))
        .on_iteration(4, |world, _| assert_eq!(order(world), vec![0, 1, 2, 3, 4]))
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            overview(OverviewCommand::Move {
                window: 4,
                target: 1,
                after: false,
            }),
            overview(OverviewCommand::Move {
                window: 4,
                target: 3,
                after: true,
            }),
            overview(OverviewCommand::Move {
                window: 2,
                target: 2,
                after: true,
            }),
            overview(OverviewCommand::Move {
                window: 999,
                target: 0,
                after: false,
            }),
        ]);
}

#[test]
fn overview_focus_reveals_exact_id_after_a_manual_scroll() {
    TestHarness::new()
        .with_windows(5)
        .on_iteration(2, |world, _| assert!(world.resource::<OverviewActive>().0))
        .on_iteration(3, |world, _| {
            assert_focused!(world, 4);
            assert!(
                world.resource::<OverviewActive>().0,
                "Input stays owned until the panel is hidden"
            );
            assert!(
                world
                    .query::<&ScrollPositionHold>()
                    .iter(world)
                    .next()
                    .is_none()
            );
            assert!(world.query::<&Scrolling>().iter(world).next().is_none());
            let entity = find_window_entity(4, world);
            assert!(
                world.get::<OverviewReady>(entity).is_some(),
                "Acknowledge native focus and committed geometry"
            );
            assert!(
                world
                    .query::<&RepositionMarker>()
                    .iter(world)
                    .next()
                    .is_none(),
                "Do not uncover a moving ribbon"
            );
            let frame = world.get::<Window>(entity).unwrap().frame();
            assert!(frame.min.x >= 0 && frame.max.x <= TEST_DISPLAY_WIDTH);
        })
        .on_iteration(4, |world, _| {
            assert!(!world.resource::<OverviewActive>().0);
            assert!(
                world
                    .query::<&OverviewHandoff>()
                    .iter(world)
                    .next()
                    .is_none()
            );
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            Event::Swipe {
                delta: 0.1,
                fingers: 3,
            },
            overview(OverviewCommand::Begin(1)),
            overview(OverviewCommand::Focus(4)),
            overview(OverviewCommand::End),
        ]);
}

#[test]
fn dismiss_keeps_input_owned_until_the_companion_releases_it() {
    TestHarness::new()
        .with_windows(3)
        .on_iteration(2, |world, _| {
            assert!(world.resource::<OverviewActive>().0);
            assert_focused!(world, 0);
            assert!(
                world
                    .query::<&OverviewHandoff>()
                    .iter(world)
                    .next()
                    .is_none()
            );
        })
        .on_iteration(3, |world, _| assert!(!world.resource::<OverviewActive>().0))
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            overview(OverviewCommand::Begin(1)),
            overview(OverviewCommand::Dismiss),
            overview(OverviewCommand::End),
        ]);
}

#[test]
fn accept_only_requests_a_target_from_the_companion_and_keeps_input_owned() {
    TestHarness::new()
        .with_windows(3)
        .on_iteration(1, |world, _| assert!(!world.resource::<OverviewActive>().0))
        .on_iteration(3, |world, _| {
            assert!(world.resource::<OverviewActive>().0);
            assert_focused!(world, 0);
        })
        .on_iteration(4, |world, _| assert!(!world.resource::<OverviewActive>().0))
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            overview(OverviewCommand::Accept),
            overview(OverviewCommand::Begin(1)),
            overview(OverviewCommand::Accept),
            overview(OverviewCommand::End),
        ]);
}

#[test]
fn overview_release_does_not_replay_deferred_auto_centering() {
    #[derive(Resource)]
    struct RevealedFrame(IRect);
    let config = crate::config::Config::try_from("[options]\nauto_center = true\n").unwrap();
    TestHarness::new()
        .with_config(config)
        .with_windows(5)
        .on_iteration(2, |world, _| {
            let entity = find_window_entity(4, world);
            assert!(world.get::<OverviewReady>(entity).is_some());
            let frame = world.get::<Window>(entity).unwrap().frame();
            world.insert_resource(RevealedFrame(frame));
        })
        .on_iteration(3, |world, _| {
            let entity = find_window_entity(4, world);
            assert_eq!(world.get::<Window>(entity).unwrap().frame(), world.resource::<RevealedFrame>().0,
                "Focus acknowledgments must be consumed while covered, without a late auto-center after release");
            assert!(world.query::<&RepositionMarker>().iter(world).next().is_none());
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            overview(OverviewCommand::Begin(1)),
            overview(OverviewCommand::Focus(4)),
            overview(OverviewCommand::End),
        ]);
}

#[test]
fn overview_suspends_scroll_input_and_closes_on_desktop_change() {
    TestHarness::new()
        .with_windows(4)
        .on_iteration(2, |world, _| {
            assert!(world.resource::<OverviewActive>().0);
            assert!(world.query::<&Scrolling>().iter(world).next().is_none());
        })
        .on_iteration(3, |world, _| assert!(!world.resource::<OverviewActive>().0))
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            overview(OverviewCommand::Begin(1)),
            Event::Swipe {
                delta: 0.2,
                fingers: 3,
            },
            Event::SpaceChanged,
        ]);
}

#[test]
fn overview_camera_pan_never_moves_or_reorders_native_windows() {
    TestHarness::new()
        .with_windows(4)
        .on_iteration(2, |world, _| {
            assert!(world.resource::<OverviewActive>().0);
            assert!(world.query::<&Scrolling>().iter(world).next().is_none());
            assert_eq!(order(world), vec![0, 1, 2, 3]);
            assert_focused!(world, 0);
        })
        .on_iteration(4, |world, _| {
            assert!(!world.resource::<OverviewActive>().0);
            assert!(world.query::<&Scrolling>().iter(world).next().is_none());
            assert_eq!(order(world), vec![0, 1, 2, 3]);
            assert_focused!(world, 0);
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            overview(OverviewCommand::Begin(1)),
            Event::OverviewPan { delta: 1.5 },
            overview(OverviewCommand::End),
            Event::OverviewPan { delta: -2.5 },
        ]);
}

#[test]
fn overview_contact_and_release_keep_momentum_out_of_the_native_strip() {
    TestHarness::new()
        .with_windows(4)
        .on_iteration(4, |world, _| {
            assert!(world.resource::<OverviewActive>().0);
            assert!(world.query::<&Scrolling>().iter(world).next().is_none());
            assert_eq!(order(world), vec![0, 1, 2, 3]);
            assert_focused!(world, 0);
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            overview(OverviewCommand::Begin(1)),
            Event::OverviewPanBegin,
            Event::OverviewPan { delta: 0.1 },
            Event::OverviewPanEnd { cancelled: false },
            overview(OverviewCommand::End),
        ]);
}

#[test]
fn overview_moves_stacked_columns_without_splitting_them() {
    TestHarness::new()
        .with_windows(4)
        .on_iteration(3, |world, _| {
            assert_eq!(order(world), vec![2, 3, 0, 1]);
            let mut strips = world.query_filtered::<&LayoutStrip, With<ActiveWorkspaceMarker>>();
            let strip = strips.single(world).unwrap();
            let first = strip.all_windows()[2];
            let second = strip.all_windows()[3];
            assert_eq!(
                strip.index_of(first).unwrap(),
                strip.index_of(second).unwrap()
            );
            assert_eq!(strip.len(), 3);
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            Event::Command {
                command: Command::Window(Operation::Focus(Direction::Nth(1))),
            },
            Event::Command {
                command: Command::Window(Operation::Stack(true)),
            },
            overview(OverviewCommand::Move {
                window: 0,
                target: 3,
                after: true,
            }),
        ]);
}

#[test]
fn overview_close_and_quit_target_native_ids_only_while_input_is_owned() {
    TestHarness::new()
        .with_app(2, "second", "SecondApp", |_| {})
        .with_windows(3)
        .with_window(8, |window| window.pid = 2)
        .on_iteration(2, |_, state| {
            assert_eq!(state.window_action_requests(), (vec![], vec![]));
        })
        .on_iteration(5, |world, state| {
            assert_eq!(state.window_action_requests(), (vec![1], vec![2]));
            assert_focused!(world, 0);
            assert!(world.resource::<OverviewActive>().0);
            assert_eq!(
                order(world),
                vec![0, 1, 2, 8],
                "Native save/cancel UI may leave every window open"
            );
        })
        .on_iteration(8, |_, state| {
            assert_eq!(state.window_action_requests(), (vec![1], vec![2]));
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            overview(OverviewCommand::Close(1)),
            overview(OverviewCommand::QuitApp(8)),
            overview(OverviewCommand::Begin(1)),
            overview(OverviewCommand::Close(1)),
            overview(OverviewCommand::QuitApp(8)),
            overview(OverviewCommand::Close(999)),
            overview(OverviewCommand::End),
            overview(OverviewCommand::QuitApp(8)),
        ]);
}

#[test]
fn overview_close_waits_for_native_destruction_before_removing_a_window() {
    TestHarness::new()
        .with_windows(3)
        .on_iteration(2, |world, state| {
            assert_eq!(state.window_action_requests().0, vec![1]);
            assert_eq!(order(world), vec![0, 1, 2]);
            state.os_close_window(1);
        })
        .on_iteration(3, |world, _| {
            assert_eq!(order(world), vec![0, 2]);
            assert!(world.resource::<OverviewActive>().0);
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            overview(OverviewCommand::Begin(1)),
            overview(OverviewCommand::Close(1)),
            Event::MenuOpened { window_id: 0 },
        ]);
}
