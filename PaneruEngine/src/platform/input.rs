use arc_swap::ArcSwap;
use core::ptr::NonNull;
use objc2::msg_send;
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2_app_kit::{NSEvent, NSEventPhase, NSEventType, NSTouch, NSTouchPhase};
use objc2_core_foundation::{
    CFMachPort, CFRetained, CFRunLoop, CFRunLoopSource, kCFRunLoopCommonModes,
};
use objc2_core_graphics::{
    CGEvent, CGEventField, CGEventFlags, CGEventTapLocation, CGEventTapOptions,
    CGEventTapPlacement, CGEventTapProxy, CGEventType, CGMomentumScrollPhase, CGScrollPhase,
};
use objc2_foundation::NSSet;
use scopeguard::ScopeGuard;
use std::ffi::c_void;
use std::marker::PhantomPinned;
use std::pin::Pin;
use std::ptr::null_mut;
use std::sync::{Arc, LazyLock};
use std::time::{Duration, Instant};
use stdext::function_name;
use tracing::{error, info, warn};

use crate::commands::{Command, Direction, Operation};
use crate::config::Config;
use crate::config::swipe::SwipeGestureDirection;
use crate::errors::{Error, Result};
use crate::events::{Event, EventSender};
use crate::platform::Modifiers;
use crate::types::commands::OverviewCommand;

const NX_DEVICEFNKEYMASK: u64 = 0x0080_0100;

/// The currently active set of passthrough keybindings, shared lock-free with
/// the `CGEvent` tap callback thread via `ArcSwap`.
static FOCUSED_PASSTHROUGH: LazyLock<ArcSwap<Vec<(u8, Modifiers)>>> =
    LazyLock::new(|| ArcSwap::from_pointee(Vec::new()));

/// Replace the passthrough keybinding set that the event tap checks on every
/// key-down. Called from the ECS thread on focus change and config reload.
pub fn set_focused_passthrough(keys: Vec<(u8, Modifiers)>) {
    FOCUSED_PASSTHROUGH.store(Arc::new(keys));
}

/// How long to suppress scroll wheel events after a vertical swipe gesture,
/// covering macOS momentum scroll that continues after finger lift.
const VERTICAL_GESTURE_SCROLL_SUPPRESS: Duration = Duration::from_millis(1200);

/// Limit repeated wheel inputs while the next window moves into view.
const WINDOW_SCROLL_INTERVAL: Duration = Duration::from_millis(180);

/// One finger, as a single gesture event saw it. Sampled out of the `NSTouch`
/// set once per event rather than read repeatedly through Objective-C, since
/// the matching in [`InputHandler::handle_swipe`] is quadratic in finger count.
#[derive(Clone)]
struct Touch {
    /// Opaque per-finger token, compared with `isEqual:` to follow one finger
    /// across events. `NSSet` iteration order is not stable, so position in the
    /// set says nothing.
    identity: Retained<AnyObject>,
    x: f64,
    y: f64,
    /// Whether the finger landed this event, which suppresses delta tracking
    /// until every finger is down.
    began: bool,
    ended: bool,
    cancelled: bool,
}

impl Touch {
    /// Samples the whole set in one pass.
    fn sample(touches: &NSSet<NSTouch>) -> Vec<Self> {
        touches
            .iter()
            .map(|touch| {
                let position = touch.normalizedPosition();
                let phase = touch.phase();
                Self {
                    identity: touch.identity(),
                    x: position.x,
                    y: position.y,
                    began: phase == NSTouchPhase::Began,
                    ended: phase == NSTouchPhase::Ended,
                    cancelled: phase == NSTouchPhase::Cancelled,
                }
            })
            .collect()
    }

    /// Whether this and `other` are the same finger.
    fn is(&self, other: &Self) -> bool {
        // SAFETY: `identity` is documented as conforming to `NSObject`, so it
        // answers `isEqual:`.
        unsafe { msg_send![&*self.identity, isEqual: &*other.identity] }
    }
}

/// Tracks one complete contact sequence, including staggered landing/lifting.
/// Origins are matched by identity so tiny moves cannot accumulate into a swipe
/// and then return to the start and be mistaken for a tap.
#[derive(Default)]
struct ThreeFingerTap {
    started: Option<Instant>,
    origins: Vec<Touch>,
    fingers_down: usize,
    three_down: bool,
    rejected: bool,
}

impl ThreeFingerTap {
    fn update(&mut self, fingers: &[Touch], ended: bool, cancelled: bool, now: Instant) -> bool {
        const MAX_DURATION: Duration = Duration::from_millis(300);
        const MAX_MOVEMENT: f64 = 0.015;

        if self.started.is_none() && fingers.iter().any(|finger| finger.began) {
            *self = Self::default();
            self.started = Some(now);
        }
        self.fingers_down = fingers
            .iter()
            .filter(|finger| !finger.ended && !finger.cancelled)
            .count();
        let Some(started) = self.started else {
            return false;
        };
        self.rejected |= cancelled || now.duration_since(started) > MAX_DURATION;
        for finger in fingers {
            self.rejected |= finger.cancelled || !finger.x.is_finite() || !finger.y.is_finite();
            if let Some(origin) = self.origins.iter_mut().find(|origin| origin.is(finger)) {
                self.rejected |= (finger.x - origin.x).hypot(finger.y - origin.y) > MAX_MOVEMENT
                    || finger.began && origin.ended;
                origin.ended |= finger.ended;
            } else if self.origins.len() < 3 {
                self.rejected |= !finger.began || self.origins.iter().any(|origin| origin.ended);
                self.origins.push(finger.clone());
            } else {
                self.rejected = true;
            }
        }
        self.three_down |= fingers.len() == 3
            && fingers
                .iter()
                .all(|finger| !finger.ended && !finger.cancelled);
        if ended
            || fingers.is_empty()
            || fingers
                .iter()
                .all(|finger| finger.ended || finger.cancelled)
        {
            let tapped = self.three_down && !self.rejected;
            *self = Self::default();
            return tapped;
        }
        false
    }

    fn owns_contact(&self) -> bool {
        self.three_down && !self.rejected
    }
}

/// Keybinds registered by the Lua runtime as `(keycode, modifiers, handler_id)`,
/// shared lock-free with the event tap. Checked before the config bindings so a
/// scripted bind can override a TOML one.
static LUA_KEYBINDS: LazyLock<ArcSwap<Vec<(u8, Modifiers, u32)>>> =
    LazyLock::new(|| ArcSwap::from_pointee(Vec::new()));

/// Replace the Lua keybind set that the event tap checks on every key-down.
/// Called from the main thread on script load and hot reload.
#[cfg(feature = "lua")]
pub fn set_lua_keybinds(keys: Vec<(u8, Modifiers, u32)>) {
    LUA_KEYBINDS.store(Arc::new(keys));
}

const SWIPE_THRESHOLD: f64 = 0.001;
const GESTURE_MINIMAL_FINGERS: usize = 3;
// WindowServer emits Dock gestures separately from AppKit's raw touch events.
// Field meanings are documented by Mac Mouse Fix's TouchSimulator.m.
const DOCK_CONTROL_EVENT: u32 = 30;

/// Outcome of an event tap health check.
///
/// A dead tap is silent: the socket keeps answering and windows keep tiling on
/// command, so only an explicit check distinguishes it from a healthy daemon.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TapHealth {
    Healthy,
    Reenabled,
    Rebuilt,
    Failed,
}

/// `InputHandler` manages low-level input events from the macOS `CGEventTap`.
/// It intercepts keyboard and mouse events, processes gestures, and dispatches them as higher-level `Event`s.
pub(super) struct InputHandler {
    /// The `EventSender` for dispatching input events.
    events: Option<EventSender>,
    /// The application `Config` for looking up keybindings.
    config: Config,
    /// The previous event's fingers, for swipe gesture detection.
    finger_position: Option<Vec<Touch>>,
    three_finger_tap: ThreeFingerTap,
    overview_swipe: OverviewSwipe,
    /// Consume macOS wheel/momentum duplicates of a raw three-finger gesture.
    overview_scroll_owned: bool,
    overview_contact_active: bool,
    /// The `CFMachPort` representing the `CGEventTap`.
    tap_port: Option<CFRetained<CFMachPort>>,
    dock_tap_port: Option<CFRetained<CFMachPort>>,
    dock_run_loop_source: Option<CFRetained<CFRunLoopSource>>,
    dock_swipe: DockSwipeGuard,
    last_overview_swipe: Option<(Instant, OverviewAxis)>,
    /// Run loop source feeding `tap_port`. Retained so the tap can be torn down
    /// and rebuilt when macOS invalidates the mach port across a sleep cycle.
    run_loop_source: Option<CFRetained<CFRunLoopSource>>,
    /// Timestamp of the last swipe gesture event. Scroll wheel events
    /// are suppressed for a short window after this to prevent the OS from
    /// scrolling windows underneath (including momentum scroll after finger lift).
    last_swipe_time: Option<Instant>,
    last_window_scroll: Option<(Instant, Direction)>,
    /// Own the native tail even if the scroll modifier is released first.
    owned_scroll: Option<Instant>,
    // Prevents from being Unpin automatically
    _pin: PhantomPinned,
}

pub(super) type PinnedInputHandler =
    ScopeGuard<Pin<Box<InputHandler>>, Box<dyn FnOnce(Pin<Box<InputHandler>>)>>;

impl InputHandler {
    #[cfg(feature = "lua")]
    pub(super) fn config(&self) -> Config {
        self.config.clone()
    }

    /// Creates a new `InputHandler` instance.
    ///
    /// # Arguments
    ///
    /// * `events` - An `EventSender` to send input-related events.
    /// * `config` - The `Config` object for looking up keybindings.
    ///
    /// # Returns
    ///
    /// A new `InputHandler`.
    pub(super) fn new(events: EventSender, config: Config) -> Self {
        InputHandler {
            events: Some(events),
            config,
            finger_position: None,
            three_finger_tap: ThreeFingerTap::default(),
            overview_swipe: OverviewSwipe::default(),
            overview_scroll_owned: false,
            overview_contact_active: false,
            tap_port: None,
            dock_tap_port: None,
            dock_run_loop_source: None,
            dock_swipe: DockSwipeGuard::default(),
            last_overview_swipe: None,
            run_loop_source: None,
            last_swipe_time: None,
            last_window_scroll: None,
            owned_scroll: None,
            _pin: PhantomPinned,
        }
    }

    /// Starts the input handler by creating and enabling a `CGEventTap`. It also sets up a cleanup hook.
    ///
    /// # Returns
    ///
    /// `Ok(())` if the event tap is created and started successfully, otherwise `Err(Error)`.
    pub(super) fn start(self) -> Result<PinnedInputHandler> {
        let mut pinned = Box::pin(self);
        // Safety: the handler stays pinned in its Box for the life of the
        // daemon, so the pointer handed to the tap callback stays valid.
        unsafe { pinned.as_mut().get_unchecked_mut() }.install_tap()?;

        Ok(scopeguard::guard(
            pinned,
            Box::new(|mut handler: Pin<Box<Self>>| {
                info!("Unregistering event_handler");
                // Safety: as above. Tearing the tap down does not move it.
                unsafe { handler.as_mut().get_unchecked_mut() }.uninstall_tap();
            }),
        ))
    }

    /// Creates the `CGEventTap` and wires its mach port into the main run loop.
    ///
    /// The caller must keep `self` pinned: the tap callback holds a raw pointer
    /// back to this handler and dereferences it on every event.
    fn install_tap(&mut self) -> Result<()> {
        let mouse_event_mask = (1 << CGEventType::MouseMoved.0)
            | (1 << CGEventType::LeftMouseDown.0)
            | (1 << CGEventType::LeftMouseUp.0)
            | (1 << CGEventType::LeftMouseDragged.0)
            | (1 << CGEventType::RightMouseDown.0)
            | (1 << CGEventType::RightMouseUp.0)
            | (1 << CGEventType::RightMouseDragged.0)
            | (1 << CGEventType::ScrollWheel.0)
            | (1 << NSEventType::Gesture.0)
            | (1 << CGEventType::KeyDown.0);

        let this = NonNull::from(&mut *self).as_ptr();
        let port = unsafe {
            CGEvent::tap_create(
                CGEventTapLocation::HIDEventTap,
                CGEventTapPlacement::HeadInsertEventTap,
                CGEventTapOptions::Default,
                mouse_event_mask,
                Some(Self::callback),
                this.cast(),
            )
        }
        .ok_or_else(|| {
            Error::PermissionDenied(format!("{}: Can not create EventTap.", function_name!()))
        })?;

        let (run_loop_source, main_loop) = CFMachPort::new_run_loop_source(None, Some(&port), 0)
            .zip(CFRunLoop::main())
            .ok_or_else(|| {
                Error::PermissionDenied(format!(
                    "{}: Unable to create run loop source",
                    function_name!()
                ))
            })?;
        CFRunLoop::add_source(&main_loop, Some(&run_loop_source), unsafe {
            kCFRunLoopCommonModes
        });

        self.tap_port = Some(port);
        self.run_loop_source = Some(run_loop_source);
        if let Err(error) = self.install_dock_tap(this) {
            self.uninstall_tap();
            return Err(error);
        }
        Ok(())
    }

    fn install_dock_tap(&mut self, this: *mut Self) -> Result<()> {
        let port = unsafe {
            CGEvent::tap_create(
                CGEventTapLocation::SessionEventTap,
                CGEventTapPlacement::HeadInsertEventTap,
                CGEventTapOptions::Default,
                1 << DOCK_CONTROL_EVENT,
                Some(Self::dock_callback),
                this.cast(),
            )
        }
        .ok_or_else(|| Error::PermissionDenied("Unable to intercept Dock gestures".into()))?;
        let (source, run_loop) = CFMachPort::new_run_loop_source(None, Some(&port), 0)
            .zip(CFRunLoop::main())
            .ok_or_else(|| Error::PermissionDenied("Unable to observe Dock gestures".into()))?;
        CFRunLoop::add_source(&run_loop, Some(&source), unsafe { kCFRunLoopCommonModes });
        self.dock_tap_port = Some(port);
        self.dock_run_loop_source = Some(source);
        Ok(())
    }

    extern "C-unwind" fn dock_callback(
        _: CGEventTapProxy,
        event_type: CGEventType,
        event: NonNull<CGEvent>,
        this: *mut c_void,
    ) -> *mut CGEvent {
        let Some(this) = NonNull::new(this) else {
            return event.as_ptr();
        };
        let this = unsafe { this.cast::<Self>().as_mut() };
        if matches!(
            event_type,
            CGEventType::TapDisabledByTimeout | CGEventType::TapDisabledByUserInput
        ) {
            if let Some(port) = &this.dock_tap_port {
                CGEvent::tap_enable(port, true);
            }
        } else if event_type.0 == DOCK_CONTROL_EVENT
            && this.handle_dock_swipe(unsafe { event.as_ref() })
        {
            return null_mut();
        }
        event.as_ptr()
    }

    fn handle_dock_swipe(&mut self, event: &CGEvent) -> bool {
        if !self.config.ribbon_overview() || self.config.disabled_space_is_visible() {
            self.dock_swipe = DockSwipeGuard::default();
            return false;
        }
        let field = |id| CGEvent::double_value_field(Some(event), CGEventField(id));
        let raw_three = self
            .finger_position
            .as_ref()
            .is_some_and(|fingers| fingers.len() == 3);
        let recent_direction = self
            .last_overview_swipe
            .filter(|(time, _)| time.elapsed() < VERTICAL_GESTURE_SCROLL_SUPPRESS)
            .map(|(_, axis)| axis);
        let overview_active = crate::ecs::overview::input_is_active();
        let physical_vertical = recent_direction.is_some()
            || self.overview_swipe.y < 0.0
                && self.overview_swipe.y.abs() > self.overview_swipe.x.abs()
            || overview_active && raw_three;
        self.dock_swipe.consume(
            field(110),
            field(123),
            if physical_vertical { 0.0 } else { field(124) },
            field(132),
            recent_direction.is_some()
                || raw_three && (overview_active || self.overview_swipe.axis != OverviewAxis::Down),
        )
    }

    fn uninstall_tap(&mut self) {
        if let Some(source) = self.dock_run_loop_source.take()
            && let Some(run_loop) = CFRunLoop::main()
        {
            CFRunLoop::remove_source(&run_loop, Some(&source), unsafe { kCFRunLoopCommonModes });
        }
        if let Some(port) = self.dock_tap_port.take() {
            CGEvent::tap_enable(&port, false);
            CFMachPort::invalidate(&port);
        }
        if let Some(run_loop_source) = self.run_loop_source.take()
            && let Some(main_loop) = CFRunLoop::main()
        {
            CFRunLoop::remove_source(&main_loop, Some(&run_loop_source), unsafe {
                kCFRunLoopCommonModes
            });
        }
        if let Some(port) = self.tap_port.take()
            && port.is_valid()
        {
            CGEvent::tap_enable(&port, false);
            CFMachPort::invalidate(&port);
        }
    }

    /// Verifies the tap still delivers events, and revives it when it does not.
    ///
    /// macOS can invalidate the tap's mach port across a sleep cycle without
    /// ever delivering `TapDisabled` to the callback. No further event then
    /// reaches the callback, so the re-arm branch there can never fire and the
    /// tap stays dead until the daemon restarts. Re-enabling an invalid port is
    /// a no-op, so that case needs a full rebuild.
    pub(super) fn ensure_tap_alive(&mut self) -> TapHealth {
        let Some(port) = self.tap_port.clone().filter(|port| port.is_valid()) else {
            return self.rebuild_tap();
        };

        let Some(dock) = self.dock_tap_port.clone().filter(|port| port.is_valid()) else {
            return self.rebuild_tap();
        };
        if CGEvent::tap_is_enabled(&port) && CGEvent::tap_is_enabled(&dock) {
            return TapHealth::Healthy;
        }

        CGEvent::tap_enable(&port, true);
        CGEvent::tap_enable(&dock, true);
        if CGEvent::tap_is_enabled(&port) && CGEvent::tap_is_enabled(&dock) {
            warn!("event tap was disabled, re-enabled it");
            TapHealth::Reenabled
        } else {
            self.rebuild_tap()
        }
    }

    fn rebuild_tap(&mut self) -> TapHealth {
        self.uninstall_tap();
        match self.install_tap() {
            Ok(()) => {
                warn!("event tap was unusable, rebuilt it");
                TapHealth::Rebuilt
            }
            Err(err) => {
                error!("unable to rebuild event tap: {err}");
                TapHealth::Failed
            }
        }
    }

    /// The C-callback function for the `CGEventTap`. It dispatches to the `input_handler` method.
    /// This function is declared as `extern "C-unwind"`.
    ///
    /// # Arguments
    ///
    /// * `_` - The `CGEventTapProxy` (unused).
    /// * `event_type` - The `CGEventType` of the event.
    /// * `event_ref` - A mutable `NonNull` pointer to the `CGEvent`.
    /// * `this` - A raw pointer to the `InputHandler` instance.
    ///
    /// # Returns
    ///
    /// A raw mutable pointer to `CGEvent`. Returns `null_mut()` if the event is intercepted.
    extern "C-unwind" fn callback(
        _: CGEventTapProxy,
        event_type: CGEventType,
        mut event_ref: NonNull<CGEvent>,
        this: *mut c_void,
    ) -> *mut CGEvent {
        if let Some(this) =
            NonNull::new(this).map(|this| unsafe { this.cast::<InputHandler>().as_mut() })
        {
            let intercept = this.input_handler(event_type, unsafe { event_ref.as_ref() });
            if intercept {
                return null_mut();
            }
        } else {
            error!("Zero passed to Event Handler.");
        }
        unsafe { event_ref.as_mut() }
    }

    /// Handles various input events received from the `CGEventTap` callback. It sends corresponding `Event`s.
    ///
    /// # Arguments
    ///
    /// * `event_type` - The `CGEventType` of the event.
    /// * `event` - A reference to the `CGEvent`.
    ///
    /// # Returns
    ///
    /// `true` if the event should be intercepted (not passed further), `false` otherwise.
    fn input_handler(&mut self, event_type: CGEventType, event: &CGEvent) -> bool {
        // Re-arm before any early return can swallow it. This is the only
        // notice macOS gives that it switched the tap off, and dropping it
        // leaves paneru deaf for the rest of the process lifetime.
        if matches!(
            event_type,
            CGEventType::TapDisabledByTimeout | CGEventType::TapDisabledByUserInput
        ) {
            self.three_finger_tap = ThreeFingerTap::default();
            warn!("Tap Disabled, re-enabling");
            if let Some(port) = &self.tap_port {
                CGEvent::tap_enable(port, true);
            }
            return false;
        }

        if self.config.disabled_space_is_visible() {
            // Pass every event to macOS, including configured hotkeys and
            // strip gestures, even during the engine's shutdown interval.
            self.finger_position = None;
            self.three_finger_tap = ThreeFingerTap::default();
            self.overview_swipe = OverviewSwipe::default();
            self.overview_scroll_owned = false;
            self.overview_contact_active = false;
            self.last_swipe_time = None;
            self.last_window_scroll = None;
            self.owned_scroll = None;
            return false;
        }

        if crate::ecs::overview::input_is_active() {
            self.three_finger_tap = ThreeFingerTap::default();
            if event_type == CGEventType::ScrollWheel {
                return self.suppress_overview_wheel(event);
            }
            if event_type == CGEventType::KeyDown
                && CGEvent::integer_value_field(Some(event), CGEventField::KeyboardEventKeycode)
                    == 53
            {
                if let Some(events) = &self.events {
                    _ = events.send(Event::Command {
                        command: Command::Overview(OverviewCommand::Dismiss),
                    });
                }
                return true;
            }
            // The overlay owns clicks, dragging and keyboard navigation. Do not
            // feed them back into hover activation or normal ribbon commands.
            if u64::from(event_type.0) != NSEventType::Gesture.0 as u64 {
                return false;
            }
        }

        let Some(events) = &self.events else {
            return false;
        };

        let flags = CGEvent::flags(Some(event));
        let mut modifiers = get_event_modifiers(flags);

        let result = match event_type {
            CGEventType::LeftMouseDown | CGEventType::RightMouseDown => {
                // A physical three-finger click uses the same reveal path, but
                // never injects Command into the event delivered to the app.
                if self.three_finger_tap.fingers_down == 3 {
                    modifiers |= Modifiers::CMD;
                }
                self.three_finger_tap.rejected = true;
                let point = CGEvent::location(Some(event));
                events.send(Event::MouseDown { point, modifiers })
            }
            CGEventType::LeftMouseUp | CGEventType::RightMouseUp => {
                let point = CGEvent::location(Some(event));
                events.send(Event::MouseUp { point, modifiers })
            }
            CGEventType::LeftMouseDragged | CGEventType::RightMouseDragged => {
                let point = CGEvent::location(Some(event));
                events.send(Event::MouseDragged { point, modifiers })
            }
            CGEventType::MouseMoved => {
                let point = CGEvent::location(Some(event));
                events.send(Event::MouseMoved { point, modifiers })
            }
            CGEventType::KeyDown => {
                let keycode =
                    CGEvent::integer_value_field(Some(event), CGEventField::KeyboardEventKeycode);
                // handle_keypress can intercept the event, so it may return true.
                return self.handle_keypress(keycode, flags);
            }
            CGEventType::ScrollWheel => {
                return self.handle_scroll_wheel(event);
            }
            // Returns directly: handle_swipe returns bool (intercept flag)
            // rather than Result like the other arms.
            _ => {
                return self.handle_swipe(event);
            }
        };
        if let Err(err) = result {
            error!("error sending event: {err}");
            // The socket is dead, so no use trying to send to it.
            // Trigger cleanup destructor, unregistering the handler.
            self.events = None;
        }
        // Do not intercept this event, let it fall through.
        false
    }

    fn suppress_overview_wheel(&mut self, event: &CGEvent) -> bool {
        let raw_three = self
            .finger_position
            .as_ref()
            .is_some_and(|fingers| fingers.len() == 3);
        let phase =
            CGEvent::integer_value_field(Some(event), CGEventField::ScrollWheelEventScrollPhase);
        let momentum =
            CGEvent::integer_value_field(Some(event), CGEventField::ScrollWheelEventMomentumPhase);
        // A fresh two-finger contact or an ordinary wheel owns its own input.
        // A three-finger native momentum tail remains consumed through its end.
        if !raw_three
            && (phase & i64::from(CGScrollPhase::Began.0) != 0 || phase == 0 && momentum == 0)
        {
            self.overview_scroll_owned = false;
        }
        raw_three || self.overview_scroll_owned
    }

    fn end_overview_contact(&mut self, overview_active: bool, cancelled: bool) {
        if self.overview_contact_active
            && overview_active
            && let Some(events) = &self.events
        {
            _ = events.send(Event::OverviewPanEnd { cancelled });
        }
        self.overview_contact_active = false;
    }

    /// Use the configured modifier to scroll the strip or select an adjacent window.
    fn handle_scroll_wheel(&mut self, event: &CGEvent) -> bool {
        // Suppress scroll events shortly after a swipe gesture to prevent
        // the OS from scrolling windows underneath, including momentum scroll events
        // that arrive after finger lift.
        if self
            .last_swipe_time
            .is_some_and(|t| t.elapsed() < VERTICAL_GESTURE_SCROLL_SUPPRESS)
        {
            return true;
        }

        let flags = CGEvent::flags(Some(event));
        let modifiers = get_event_modifiers(flags);

        let target_modifier = self.config.swipe_scroll_modifier();
        let vertical_mod = self.config.swipe_scroll_vertical_modifier();

        // Check the combined modifier (base + vertical) first, then fall back to
        // base-only. matches() rejects extra modifier groups, so cmd+shift held
        // would fail a cmd-only check. We need to accept both.
        let base_match = target_modifier.matches(modifiers);
        let combined_match =
            vertical_mod.is_some_and(|vm| (target_modifier | vm).matches(modifiers));
        let phase =
            CGEvent::integer_value_field(Some(event), CGEventField::ScrollWheelEventScrollPhase);
        let momentum =
            CGEvent::integer_value_field(Some(event), CGEventField::ScrollWheelEventMomentumPhase);
        if momentum != 0 {
            // Paneru derives one adjustable coast from the physical input.
            // Consuming the OS tail avoids double inertia and background scroll.
            let owned = self
                .owned_scroll
                .is_some_and(|last| last.elapsed() < Duration::from_secs(2));
            if owned {
                self.owned_scroll = Some(Instant::now());
                if momentum == i64::from(CGMomentumScrollPhase::Begin.0)
                    && let Some(events) = &self.events
                {
                    // Some devices omit the zero-delta physical end event.
                    _ = events.send(Event::TouchpadUp);
                }
            }
            return owned || base_match || combined_match;
        }
        if phase & i64::from(CGScrollPhase::Began.0) != 0 {
            self.owned_scroll = None;
        }
        if !combined_match && !base_match {
            if phase & i64::from(CGScrollPhase::Ended.0 | CGScrollPhase::Cancelled.0) != 0
                && self
                    .owned_scroll
                    .is_some_and(|last| last.elapsed() < Duration::from_secs(2))
                && let Some(events) = &self.events
            {
                return finish_scroll_phase(events, phase);
            }
            return false;
        }

        if let Some(events) = &self.events {
            self.owned_scroll = Some(Instant::now());
            if !combined_match
                && !self.config.swipe_scroll_window_step()
                && phase & i64::from(CGScrollPhase::Began.0) != 0
            {
                _ = events.send(Event::TouchpadDown);
            }
            let h_delta = CGEvent::double_value_field(
                Some(event),
                CGEventField::ScrollWheelEventFixedPtDeltaAxis2,
            );
            let v_delta = CGEvent::double_value_field(
                Some(event),
                CGEventField::ScrollWheelEventFixedPtDeltaAxis1,
            );

            // Vertical workspace switching when vertical modifier is also held.
            // Don't set last_vertical_gesture here: the suppress timer is for
            // trackpad momentum scroll, not discrete wheel ticks.
            if combined_match && v_delta.abs() > 0.001 {
                _ = events.send(Event::VerticalScrollTick { delta: v_delta });
                return true;
            }

            // If we have any horizontal delta, or if there's only vertical delta, use it.
            let delta = if h_delta.abs() > 0.001 {
                h_delta
            } else if v_delta.abs() > 0.001 {
                v_delta
            } else {
                0.0
            };

            if delta.abs() > 0.001 {
                if self.config.swipe_scroll_window_step() {
                    let direction = scroll_step_direction(&self.config, delta);
                    if accept_window_scroll(
                        &mut self.last_window_scroll,
                        &direction,
                        momentum != 0,
                        Instant::now(),
                    ) {
                        _ = events.send(Event::Command {
                            command: Command::Window(Operation::Focus(direction)),
                        });
                    }
                } else {
                    _ = events.send(Event::Scroll { delta });
                }
                finish_scroll_phase(events, phase);
                return true; // Intercept: don't let the window scroll
            }
            return finish_scroll_phase(events, phase);
        }
        false
    }

    /// Handles swipe gesture events. Routes to horizontal `Swipe` or vertical
    /// `VerticalSwipe` based on axis dominance. Returns true to intercept the event.
    fn handle_swipe(&mut self, event: &CGEvent) -> bool {
        let overview_active = crate::ecs::overview::input_is_active();
        let configured = if overview_active {
            Some(3)
        } else {
            self.config.swipe_gesture_fingers()
        };
        let configured = configured.filter(|fingers| *fingers >= GESTURE_MINIMAL_FINGERS);
        let taps_enabled = !overview_active
            && (self.config.preserve_scroll_until_click() || configured == Some(3));
        if configured.is_none() && !taps_enabled {
            // No valid gesture is configured, so leave native macOS gestures alone.
            return false;
        }

        objc2::rc::autoreleasepool(|_| {
            let Some(ns_event) = NSEvent::eventWithCGEvent(event) else {
                error!("{}: Unable to convert CGEvent to NSEvent", function_name!());
                return false;
            };
            if ns_event.r#type() != NSEventType::Gesture {
                return false;
            }

            let fingers = Touch::sample(&ns_event.allTouches());
            let phase = ns_event.phase();
            let tap_owned = taps_enabled && self.handle_three_finger_tap(&fingers, phase, event);
            let Some(configured_fingers) = configured else {
                return tap_owned;
            };

            // Fingers lifted off touchpad.
            if (phase.contains(NSEventPhase::Cancelled) || phase.contains(NSEventPhase::Ended))
                && self.events.is_some()
            {
                self.end_overview_contact(overview_active, phase.contains(NSEventPhase::Cancelled));
                if let Some(events) = &self.events {
                    if phase.contains(NSEventPhase::Cancelled) {
                        _ = events.send(Event::TouchpadDown);
                    }
                    _ = events.send(Event::TouchpadUp);
                }
                self.finger_position = None;
                let consumed = tap_owned
                    || self.overview_swipe.axis == OverviewAxis::Up
                    || overview_active && self.overview_scroll_owned
                    || self.overview_swipe.axis == OverviewAxis::Down
                        && self
                            .last_overview_swipe
                            .is_some_and(|(_, axis)| axis == OverviewAxis::Down);
                self.overview_swipe = OverviewSwipe::default();
                return consumed;
            }

            if fingers.iter().any(|finger| finger.began) {
                self.last_overview_swipe = None;
            }
            if !gesture_should_intercept(Some(configured_fingers), fingers.len()) {
                self.end_overview_contact(overview_active, true);
                if self.finger_position.take().is_some()
                    && let Some(events) = &self.events
                {
                    _ = events.send(Event::TouchpadUp);
                }
                self.overview_swipe = OverviewSwipe::default();
                return tap_owned;
            }
            if fingers.iter().any(|finger| finger.began) {
                self.overview_swipe = OverviewSwipe::default();
                if overview_active {
                    self.overview_scroll_owned = true;
                    self.overview_contact_active = true;
                    if let Some(events) = &self.events {
                        _ = events.send(Event::OverviewPanBegin);
                    }
                }
                // A fresh gesture: nothing carries over from the last one.
                if let Some(events) = &self.events {
                    _ = events.send(Event::TouchpadDown);
                }
            }

            if fingers.len() < GESTURE_MINIMAL_FINGERS {
                return false;
            }

            if fingers.iter().all(|finger| !finger.began)
                && let Some(prev) = &self.finger_position
            {
                // Match touches by identity rather than relying on NSSet
                // iteration order, which is not guaranteed to be stable.
                let (x_deltas, y_deltas): (Vec<f64>, Vec<f64>) = fingers
                    .iter()
                    .filter_map(|current| {
                        prev.iter()
                            .find(|previous| previous.is(current))
                            .map(|previous| (previous.x - current.x, previous.y - current.y))
                    })
                    .unzip();

                let intercept = self.handle_gesture_delta(
                    &x_deltas,
                    &y_deltas,
                    configured_fingers,
                    overview_active,
                );
                self.finger_position = Some(fingers);
                return intercept;
            }
            self.finger_position = Some(fingers);

            // If we have 3 or more fingers on the trackpad, we intercept the event
            // to prevent it from being interpreted as a scroll by the OS.
            true
        })
    }

    fn handle_three_finger_tap(
        &mut self,
        fingers: &[Touch],
        phase: NSEventPhase,
        event: &CGEvent,
    ) -> bool {
        let tapped = self.three_finger_tap.update(
            fingers,
            phase.contains(NSEventPhase::Ended),
            phase.contains(NSEventPhase::Cancelled),
            Instant::now(),
        );
        if tapped && let Some(events) = &self.events {
            _ = events.send(Event::ThreeFingerTap {
                point: CGEvent::location(Some(event)),
            });
        }
        tapped || self.three_finger_tap.owns_contact()
    }

    fn handle_gesture_delta(
        &mut self,
        x_deltas: &[f64],
        y_deltas: &[f64],
        configured_fingers: usize,
        overview_active: bool,
    ) -> bool {
        let Some(events) = &self.events else {
            return false;
        };
        let x_sum: f64 = x_deltas.iter().sum();
        let y_sum: f64 = y_deltas.iter().sum();
        let was_pending = self.overview_swipe.axis == OverviewAxis::Pending;
        if (self.config.ribbon_overview() || overview_active)
            && configured_fingers == 3
            && x_deltas.len() == 3
        {
            if let Some(action) =
                self.overview_swipe
                    .action(x_sum / 3.0, y_sum / 3.0, overview_active)
            {
                _ = events.send(Event::Command {
                    command: Command::Overview(action),
                });
                self.last_swipe_time = Some(Instant::now());
                self.last_overview_swipe = Some((Instant::now(), self.overview_swipe.axis));
            }
            match self.overview_swipe.axis {
                OverviewAxis::Pending | OverviewAxis::Up => return true,
                OverviewAxis::Down
                    if overview_active
                        || self
                            .last_overview_swipe
                            .is_some_and(|(_, axis)| axis == OverviewAxis::Down) =>
                {
                    return true;
                }
                OverviewAxis::Down if !self.config.swipe_vertical() => return false,
                OverviewAxis::Horizontal if x_sum.abs() < y_sum.abs() => return true,
                _ => {}
            }
        }
        if overview_active {
            if self.overview_swipe.axis == OverviewAxis::Horizontal
                && x_sum.is_finite()
                && x_sum != 0.0
            {
                let direction = match self.config.swipe_gesture_direction() {
                    SwipeGestureDirection::Natural => 1.0,
                    SwipeGestureDirection::Reversed => -1.0,
                };
                if !self.overview_contact_active {
                    _ = events.send(Event::OverviewPanBegin);
                    self.overview_contact_active = true;
                }
                _ = events.send(Event::OverviewPan {
                    delta: (if was_pending {
                        self.overview_swipe.x * 3.0
                    } else {
                        x_sum
                    }) * self.config.swipe_sensitivity()
                        * direction,
                });
                self.overview_scroll_owned = true;
            }
            return true;
        }
        if x_sum.abs() >= y_sum.abs() {
            if horizontal_swipe_detected(
                x_deltas,
                self.config.swipe_three_finger_paging() || self.config.swipe_magnetic_snapping(),
            ) {
                _ = events.send(Event::Swipe {
                    delta: x_sum,
                    fingers: x_deltas.len(),
                });
                self.last_swipe_time = Some(Instant::now());
            }
        } else if y_deltas.iter().all(|p| p.abs() > SWIPE_THRESHOLD) {
            if !self.config.swipe_vertical() {
                return false;
            }
            _ = events.send(Event::VerticalSwipe {
                delta: y_sum,
                fingers: y_deltas.len(),
            });
            self.last_swipe_time = Some(Instant::now());
        }
        true
    }

    /// Handles key press events. It determines the modifier mask and attempts to find a matching keybinding in the configuration.
    /// If a binding is found, it sends a `Command` event and intercepts the key press.
    ///
    /// # Arguments
    ///
    /// * `keycode` - The key code of the pressed key.
    /// * `eventflags` - The `CGEventFlags` representing active modifiers.
    ///
    /// # Returns
    ///
    /// `true` if the key press was handled and should be intercepted, `false` otherwise.
    fn handle_keypress(&self, keycode: i64, eventflags: CGEventFlags) -> bool {
        let Some(events) = &self.events else {
            return false;
        };

        let mask = get_event_modifiers(eventflags);

        // On a native fullscreen space, keybindings are still intercepted so
        // that paneru can actively switch back to the previous workspace.
        // Non-paneru keys pass through naturally (find_keybind returns None).

        let keycode = keycode.try_into().ok();
        keycode
            .and_then(|keycode| {
                let passthrough = FOCUSED_PASSTHROUGH.load();
                if passthrough
                    .iter()
                    .any(|(c, m)| *c == keycode && m.matches(mask))
                {
                    return None;
                }
                // Lua-registered binds take precedence over the TOML config.
                let lua_binds = LUA_KEYBINDS.load();
                if let Some((_, _, id)) = lua_binds
                    .iter()
                    .find(|(c, m, _)| *c == keycode && m.matches(mask))
                {
                    return Some(Command::Lua(*id));
                }
                self.config.find_keybind(keycode, mask)
            })
            .and_then(|command| {
                events
                    .send(Event::Command { command })
                    .inspect_err(|err| error!("Error sending command: {err}"))
                    .ok()
            })
            .is_some()
    }
}

/// Once claimed, keep every Dock packet, including reversals and duplicate
/// end packets after the raw touches disappear. Four-finger/native gestures
/// never acquire ownership without a matching raw three-finger gesture.
#[derive(Default)]
struct DockSwipeGuard {
    owned: bool,
}
impl DockSwipeGuard {
    #[allow(
        clippy::float_cmp,
        reason = "CGEvent's floating accessor carries exact integer protocol tags here"
    )]
    fn consume(
        &mut self,
        subtype: f64,
        axis: f64,
        progress: f64,
        phase: f64,
        eligible: bool,
    ) -> bool {
        if subtype != 23.0 || axis != 2.0 {
            return false;
        }
        if phase == 1.0 {
            self.owned = false;
        }
        // Raw touches can end before the Dock emits its final packet. Once
        // owned, release only at the next sequence's Began (or an explicit
        // config/Space bypass in handle_dock_swipe), never at raw finger lift.
        if eligible && progress >= 0.0 {
            self.owned = true;
        }
        self.owned
    }
}

/// Lock direction using accumulated physical movement, independent of scroll
/// direction settings. Each vertical gesture can emit only one overview action.
#[derive(Clone, Copy, Default, PartialEq, Eq)]
enum OverviewAxis {
    #[default]
    Pending,
    Horizontal,
    Up,
    Down,
}
#[derive(Default)]
struct OverviewSwipe {
    x: f64,
    y: f64,
    axis: OverviewAxis,
}
impl OverviewSwipe {
    fn advance(&mut self, x: f64, y: f64) -> bool {
        if self.axis != OverviewAxis::Pending {
            return false;
        }
        self.x += x;
        self.y += y;
        if self.x.abs() > 0.012 && self.x.abs() > self.y.abs() * 1.25 {
            self.axis = OverviewAxis::Horizontal;
        } else if self.y.abs() > 0.035 && self.y.abs() > self.x.abs() * 1.25 {
            self.axis = if self.y < 0.0 {
                OverviewAxis::Up
            } else {
                OverviewAxis::Down
            };
            return true;
        }
        false
    }
    fn action(&mut self, x: f64, y: f64, overview_active: bool) -> Option<OverviewCommand> {
        if !self.advance(x, y) {
            return None;
        }
        match self.axis {
            OverviewAxis::Up => Some(OverviewCommand::Show),
            OverviewAxis::Down if overview_active => Some(OverviewCommand::Accept),
            _ => None,
        }
    }
}

fn gesture_should_intercept(configured_fingers: Option<usize>, actual_fingers: usize) -> bool {
    configured_fingers.is_some_and(|configured| {
        configured >= GESTURE_MINIMAL_FINGERS && configured == actual_fingers
    })
}

// Remote and accessibility input can send group flags without side flags.
// Use the group only when the event does not specify a side.
fn get_event_modifiers(eventflags: CGEventFlags) -> Modifiers {
    const GROUP_FLAGS: [(Modifiers, u64); 4] = [
        (Modifiers::ALT, CGEventFlags::MaskAlternate.0),
        (Modifiers::SHIFT, CGEventFlags::MaskShift.0),
        (Modifiers::CMD, CGEventFlags::MaskCommand.0),
        (Modifiers::CTRL, CGEventFlags::MaskControl.0),
    ];

    GROUP_FLAGS
        .iter()
        .fold(get_modifiers(eventflags), |modifiers, (group, flag)| {
            if !modifiers.intersects(*group) && eventflags.0 & flag != 0 {
                modifiers | *group
            } else {
                modifiers
            }
        })
}

fn get_modifiers(eventflags: CGEventFlags) -> Modifiers {
    const MODIFIER_MASKS: [(Modifiers, u64); 8] = [
        (Modifiers::LALT, 0x0000_0020),
        (Modifiers::RALT, 0x0000_0040),
        (Modifiers::LSHIFT, 0x0000_0002),
        (Modifiers::RSHIFT, 0x0000_0004),
        (Modifiers::LCMD, 0x0000_0008),
        (Modifiers::RCMD, 0x0000_0010),
        (Modifiers::LCTRL, 0x0000_0001),
        (Modifiers::RCTRL, 0x0000_2000),
    ];

    // Fn key should be checked for separately, because pressing
    // some keys (i.e. leftarrow) seems to inadvertently toggling it.
    if eventflags.0 == NX_DEVICEFNKEYMASK {
        tracing::debug!("event flags {:#x}", eventflags.0);
        return Modifiers::FN;
    }

    MODIFIER_MASKS
        .iter()
        .fold(Modifiers::empty(), |modifiers, (modifier, mask)| {
            if eventflags.0 & mask != 0 {
                modifiers | *modifier
            } else {
                modifiers
            }
        })
}

/// A zero-delta phase event still ends the physical input. Cancellation
/// clears velocity before release, so it cannot accidentally launch a fling.
fn finish_scroll_phase(events: &EventSender, phase: i64) -> bool {
    if phase & i64::from(CGScrollPhase::Ended.0 | CGScrollPhase::Cancelled.0) == 0 {
        return false;
    }
    if phase & i64::from(CGScrollPhase::Cancelled.0) != 0 {
        _ = events.send(Event::TouchpadDown);
    }
    _ = events.send(Event::TouchpadUp);
    true
}

fn scroll_step_direction(config: &Config, delta: f64) -> Direction {
    let natural = matches!(
        config.swipe_gesture_direction(),
        SwipeGestureDirection::Natural
    );
    if (delta > 0.0) == natural {
        Direction::East
    } else {
        Direction::West
    }
}

fn accept_window_scroll(
    last: &mut Option<(Instant, Direction)>,
    direction: &Direction,
    momentum: bool,
    now: Instant,
) -> bool {
    if momentum
        || last.as_ref().is_some_and(|(time, previous)| {
            previous == direction && now.duration_since(*time) < WINDOW_SCROLL_INTERVAL
        })
    {
        return false;
    }
    *last = Some((now, direction.clone()));
    true
}

fn horizontal_swipe_detected(deltas: &[f64], paging: bool) -> bool {
    if paging && deltas.len() == 3 {
        deltas.iter().all(|delta| delta.is_finite())
            && deltas.iter().sum::<f64>().abs() > f64::EPSILON
    } else {
        !deltas.is_empty() && deltas.iter().all(|delta| delta.abs() > SWIPE_THRESHOLD)
    }
}

#[test]
fn paging_recognizes_tiny_three_finger_motion_without_treating_a_touch_as_a_swipe() {
    assert!(horizontal_swipe_detected(&[0.00001; 3], true));
    assert!(!horizontal_swipe_detected(&[0.00001; 3], false));
    assert!(!horizontal_swipe_detected(&[0.0; 3], true));
    assert!(!horizontal_swipe_detected(&[f64::NAN; 3], true));
    assert!(!horizontal_swipe_detected(&[0.00001; 4], true));
    assert!(!horizontal_swipe_detected(&[], true));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tap_fingers(count: usize) -> Vec<Touch> {
        (0..count)
            .map(|_| Touch {
                identity: objc2_foundation::NSObject::new().into(),
                x: 0.5,
                y: 0.5,
                began: true,
                ended: false,
                cancelled: false,
            })
            .collect()
    }

    fn stationary(fingers: &[Touch]) -> Vec<Touch> {
        fingers
            .iter()
            .cloned()
            .map(|mut finger| {
                finger.began = false;
                finger
            })
            .collect()
    }

    #[test]
    fn three_finger_tap_accepts_staggered_contacts_and_small_jitter_once() {
        let now = Instant::now();
        let fingers = tap_fingers(3);
        let mut tap = ThreeFingerTap::default();
        assert!(!tap.update(&fingers[..1], false, false, now));
        let mut next = fingers.clone();
        next[0].began = false;
        assert!(!tap.update(&next[..2], false, false, now + Duration::from_millis(20)));
        next[1].began = false;
        assert!(!tap.update(&next, false, false, now + Duration::from_millis(40)));
        assert!(tap.owns_contact());
        next = stationary(&next);
        next.reverse();
        next[0].x += 0.002;
        next[1].y -= 0.003;
        assert!(!tap.update(&next, false, false, now + Duration::from_millis(70)));
        next[0].ended = true;
        assert!(!tap.update(&next, false, false, now + Duration::from_millis(90)));
        next.remove(0);
        next[0].ended = true;
        assert!(!tap.update(&next, false, false, now + Duration::from_millis(100)));
        next.remove(0);
        next[0].ended = true;
        assert!(tap.update(&next, true, false, now + Duration::from_millis(110)));
        assert!(!tap.update(&[], true, false, now + Duration::from_millis(120)));
        assert!(!tap.owns_contact());
    }

    #[test]
    fn three_finger_tap_rejects_other_counts_holds_cancellation_and_release_motion() {
        let now = Instant::now();
        for count in [1, 2, 4] {
            let mut tap = ThreeFingerTap::default();
            tap.update(&tap_fingers(count), false, false, now);
            assert!(!tap.update(&[], true, false, now + Duration::from_millis(100)));
        }
        for (duration, cancelled, movement) in [
            (301, false, 0.0),
            (100, true, 0.0),
            (100, false, 0.02),
            (100, false, f64::NAN),
        ] {
            let fingers = tap_fingers(3);
            let mut tap = ThreeFingerTap::default();
            tap.update(&fingers, false, false, now);
            let mut release = stationary(&fingers);
            release[0].y += movement;
            assert!(!tap.update(
                &release,
                true,
                cancelled,
                now + Duration::from_millis(duration)
            ));
        }
    }

    #[test]
    fn three_finger_swipe_cannot_become_a_tap_by_returning_to_its_origin() {
        let now = Instant::now();
        let fingers = tap_fingers(3);
        let mut tap = ThreeFingerTap::default();
        tap.update(&fingers, false, false, now);
        for step in 1_u32..=20 {
            let mut moved = stationary(&fingers);
            moved[0].x += f64::from(step) * 0.001;
            tap.update(
                &moved,
                false,
                false,
                now + Duration::from_millis(u64::from(step)),
            );
        }
        assert!(!tap.update(
            &stationary(&fingers),
            true,
            false,
            now + Duration::from_millis(100)
        ));
    }

    #[test]
    fn replacing_a_finger_or_adding_a_fourth_rejects_the_complete_sequence() {
        let now = Instant::now();
        for replacement in [false, true] {
            let fingers = tap_fingers(3);
            let mut tap = ThreeFingerTap::default();
            tap.update(&fingers, false, false, now);
            let mut next = stationary(&fingers);
            if replacement {
                next.remove(0);
            }
            next.extend(tap_fingers(1));
            tap.update(&next, false, false, now + Duration::from_millis(50));
            assert!(!tap.update(&[], true, false, now + Duration::from_millis(100)));
        }
    }

    #[test]
    fn physical_three_finger_click_reveals_without_a_second_tap_or_native_command_flag() {
        let (sender, receiver) = EventSender::new();
        let mut handler = InputHandler::new(sender, Config::default());
        let event = CGEvent::new(None).expect("local event, never posted");
        CGEvent::set_flags(Some(&event), CGEventFlags(0));
        // An ordinary click must not prevent the next tap from being recognized.
        assert!(!handler.input_handler(CGEventType::LeftMouseDown, &event));
        assert!(
            matches!(receiver.try_recv(), Ok(Event::MouseDown { modifiers, .. }) if modifiers.is_empty())
        );
        let fingers = tap_fingers(3);
        let now = Instant::now();
        handler.three_finger_tap.update(&fingers, false, false, now);
        assert!(!handler.input_handler(CGEventType::LeftMouseDown, &event));
        assert!(
            matches!(receiver.try_recv(), Ok(Event::MouseDown { modifiers, .. }) if modifiers.intersects(Modifiers::CMD))
        );
        assert_eq!(CGEvent::flags(Some(&event)), CGEventFlags(0));
        assert!(!handler.three_finger_tap.update(
            &[],
            true,
            false,
            now + Duration::from_millis(100)
        ));
        handler
            .three_finger_tap
            .update(&tap_fingers(3), false, false, now);
        assert!(handler.three_finger_tap.update(
            &[],
            true,
            false,
            now + Duration::from_millis(100)
        ));
    }

    #[test]
    fn physical_three_finger_click_can_finish_a_swipe_without_relanding() {
        let (sender, receiver) = EventSender::new();
        let mut handler = InputHandler::new(sender, Config::default());
        let event = CGEvent::new(None).expect("local event, never posted");
        let fingers = tap_fingers(3);
        let now = Instant::now();
        handler.three_finger_tap.update(&fingers, false, false, now);
        let mut moved = stationary(&fingers);
        for finger in &mut moved {
            finger.x += 0.1;
        }
        handler
            .three_finger_tap
            .update(&moved, false, false, now + Duration::from_secs(1));
        assert!(
            !handler.three_finger_tap.owns_contact(),
            "this is no longer a tap"
        );
        assert!(!handler.input_handler(CGEventType::LeftMouseDown, &event));
        assert!(
            matches!(receiver.try_recv(), Ok(Event::MouseDown { modifiers, .. }) if modifiers.intersects(Modifiers::CMD))
        );
    }

    #[test]
    fn magnetic_mode_receives_precise_motion_with_paging_off() {
        let (sender, receiver) = EventSender::new();
        let config = Config::try_from("[swipe]\nmagnetic_snapping = true\nthree_finger_paging = false\n[swipe.gesture]\nfingers_count = 3\n").unwrap();
        let mut handler = InputHandler::new(sender, config);
        assert!(handler.handle_gesture_delta(&[0.00001; 3], &[0.0; 3], 3, false));
        assert!(
            matches!(receiver.try_recv().unwrap(), Event::Swipe { delta, fingers: 3 } if delta > 0.0)
        );
        assert!(receiver.try_recv().is_err());
    }

    #[test]
    fn overview_keeps_two_finger_scrolls_and_consumes_three_finger_wheel_duplicates() {
        let (sender, _receiver) = EventSender::new();
        let mut handler = InputHandler::new(sender, Config::default());
        assert!(!handler.suppress_overview_wheel(&scroll_event(
            CGScrollPhase::Began,
            0,
            false,
            1.0
        )));
        assert!(!handler.suppress_overview_wheel(&scroll_event(CGScrollPhase(0), 2, false, 1.0)));
        handler.overview_scroll_owned = true;
        for momentum in [1, 2, 4] {
            assert!(handler.suppress_overview_wheel(&scroll_event(
                CGScrollPhase(0),
                momentum,
                false,
                1.0
            )));
        }
        assert!(
            !handler.suppress_overview_wheel(&scroll_event(CGScrollPhase::Began, 0, false, 1.0)),
            "A new two-finger gesture works immediately after three-finger scrolling"
        );
        handler.overview_scroll_owned = true;
        assert!(
            !handler.suppress_overview_wheel(&scroll_event(CGScrollPhase(0), 0, false, 1.0)),
            "An ordinary mouse wheel also retains its input"
        );
    }

    fn scroll_event(
        phase: CGScrollPhase,
        momentum: i64,
        modified: bool,
        delta: f64,
    ) -> CFRetained<CGEvent> {
        let event = CGEvent::new_scroll_wheel_event2(
            None,
            objc2_core_graphics::CGScrollEventUnit::Pixel,
            2,
            0,
            1,
            0,
        )
        .expect("local event; never posted");
        CGEvent::set_flags(
            Some(&event),
            if modified {
                CGEventFlags::MaskAlternate
            } else {
                CGEventFlags(0)
            },
        );
        CGEvent::set_integer_value_field(
            Some(&event),
            CGEventField::ScrollWheelEventScrollPhase,
            i64::from(phase.0),
        );
        CGEvent::set_integer_value_field(
            Some(&event),
            CGEventField::ScrollWheelEventMomentumPhase,
            momentum,
        );
        CGEvent::set_double_value_field(
            Some(&event),
            CGEventField::ScrollWheelEventFixedPtDeltaAxis2,
            delta,
        );
        event
    }

    #[test]
    fn modifier_scroll_owns_native_tails_after_modifier_release_without_double_travel() {
        let (sender, receiver) = EventSender::new();
        let config = Config::try_from("[swipe.scroll]\nmodifier = 'alt'\n").expect("valid config");
        let mut handler = InputHandler::new(sender, config);
        assert!(handler.handle_scroll_wheel(&scroll_event(CGScrollPhase::Began, 0, true, 1.0)));
        assert!(matches!(receiver.try_recv(), Ok(Event::TouchpadDown)));
        assert!(matches!(receiver.try_recv(), Ok(Event::Scroll { .. })));
        assert!(handler.handle_scroll_wheel(&scroll_event(CGScrollPhase::Ended, 0, false, 0.0)));
        assert!(matches!(receiver.try_recv(), Ok(Event::TouchpadUp)));
        assert!(handler.handle_scroll_wheel(&scroll_event(CGScrollPhase(0), 1, false, 2.0)));
        assert!(matches!(receiver.try_recv(), Ok(Event::TouchpadUp)));
        assert!(handler.handle_scroll_wheel(&scroll_event(CGScrollPhase(0), 2, false, 1.0)));
        assert!(
            receiver.try_recv().is_err(),
            "native momentum must not add another scroll delta"
        );
        assert!(
            !handler.handle_scroll_wheel(&scroll_event(CGScrollPhase::Began, 0, false, 1.0)),
            "a fresh unmodified gesture belongs to the app"
        );
        assert!(!handler.handle_scroll_wheel(&scroll_event(CGScrollPhase(0), 1, false, 1.0)));
    }

    #[test]
    fn cancelled_scroll_clears_velocity_and_releases_contact_even_without_travel() {
        let (sender, receiver) = EventSender::new();
        assert!(finish_scroll_phase(
            &sender,
            i64::from(CGScrollPhase::Cancelled.0)
        ));
        assert!(matches!(receiver.try_recv(), Ok(Event::TouchpadDown)));
        assert!(matches!(receiver.try_recv(), Ok(Event::TouchpadUp)));
        assert!(receiver.try_recv().is_err());
    }

    #[test]
    fn input_config_observes_shared_desktop_exclusions() {
        let (sender, _receiver) = EventSender::new();
        let handler = InputHandler::new(sender, Config::default());
        let shared = handler.config();
        shared.replace_inner_from(
            &Config::try_from("[options]\ndisabled_spaces = [2, 20]\n").expect("valid config"),
        );
        assert_eq!(handler.config.disabled_spaces(), vec![2, 20]);
        shared.replace_inner_from(&Config::default());
        assert!(handler.config.disabled_spaces().is_empty());
    }

    fn step_config(extra: &str) -> Config {
        Config::try_from(format!(
            "[options]\n[bindings]\n[swipe.scroll]\nmodifier = 'alt'\nwindow_step = true\n{extra}"
        ).as_str()).expect("valid test config")
    }

    #[test]
    fn wheel_steps_use_delta_sign_and_configured_direction() {
        for reversed in [false, true] {
            let config = step_config(if reversed {
                "[swipe.gesture]\ndirection = 'Reversed'\n"
            } else {
                ""
            });
            for delta in [0.1, 1.0, 3.0, 120.0] {
                for signed_delta in [delta, -delta] {
                    let direction = scroll_step_direction(&config, signed_delta);
                    let expected = if (signed_delta > 0.0) == reversed {
                        Direction::West
                    } else {
                        Direction::East
                    };
                    assert_eq!(direction, expected);
                }
            }
        }
    }

    #[test]
    fn wheel_scroll_stays_free_unless_step_mode_is_enabled() {
        assert!(!Config::default().swipe_scroll_window_step());
        let disabled = Config::try_from("[swipe.scroll]\nwindow_step = false\n").unwrap();
        assert!(!disabled.swipe_scroll_window_step());
        let enabled = Config::try_from("[swipe.scroll]\nwindow_step = true\n").unwrap();
        assert!(enabled.swipe_scroll_window_step());
    }

    #[test]
    fn wheel_steps_limit_repeats_but_allow_immediate_reversal() {
        let now = Instant::now();
        let mut last = None;
        assert!(accept_window_scroll(
            &mut last,
            &Direction::East,
            false,
            now
        ));
        assert!(!accept_window_scroll(
            &mut last,
            &Direction::East,
            false,
            now + Duration::from_millis(100)
        ));
        assert!(accept_window_scroll(
            &mut last,
            &Direction::East,
            false,
            now + WINDOW_SCROLL_INTERVAL
        ));
        assert!(accept_window_scroll(
            &mut last,
            &Direction::West,
            false,
            now + WINDOW_SCROLL_INTERVAL
        ));
    }

    #[test]
    fn wheel_momentum_does_not_select_a_window_or_delay_the_next_input() {
        let now = Instant::now();
        let mut last = None;
        assert!(!accept_window_scroll(
            &mut last,
            &Direction::East,
            true,
            now
        ));
        assert!(last.is_none());
        assert!(accept_window_scroll(
            &mut last,
            &Direction::East,
            false,
            now
        ));
        assert!(!accept_window_scroll(
            &mut last,
            &Direction::West,
            true,
            now
        ));
        assert!(accept_window_scroll(
            &mut last,
            &Direction::East,
            false,
            now + WINDOW_SCROLL_INTERVAL
        ));
    }

    #[test]
    fn wheel_steps_focus_adjacent_windows_and_stop_at_strip_edges() {
        use crate::tests::TestHarness;

        let config = step_config("");
        let mut events = vec![Event::MenuOpened { window_id: 0 }];
        events.extend(
            [120.0, 3.0, 3.0, -120.0, -3.0, -3.0].map(|delta| Event::Command {
                command: Command::Window(Operation::Focus(scroll_step_direction(&config, delta))),
            }),
        );
        let mut harness = TestHarness::new().with_config(config).with_windows(3);
        for (iteration, expected) in [0, 1, 2, 2, 1, 0, 0].into_iter().enumerate() {
            harness = harness.on_iteration(iteration, move |world, _| {
                crate::assert_focused!(world, expected);
                assert_eq!(
                    world.query::<&crate::ecs::Scrolling>().iter(world).count(),
                    0
                );
            });
        }
        harness.run(events);
    }

    const NX_DEVICELALTKEYMASK: u64 = 0x0000_0020;
    const NX_DEVICERALTKEYMASK: u64 = 0x0000_0040;
    const NX_DEVICELSHIFTKEYMASK: u64 = 0x0000_0002;
    const NX_DEVICERSHIFTKEYMASK: u64 = 0x0000_0004;
    const NX_DEVICELCMDKEYMASK: u64 = 0x0000_0008;
    const NX_DEVICERCMDKEYMASK: u64 = 0x0000_0010;
    const NX_DEVICELCTLKEYMASK: u64 = 0x0000_0001;
    const NX_DEVICERCTLKEYMASK: u64 = 0x0000_2000;

    #[test]
    fn no_modifiers() {
        assert_eq!(get_modifiers(CGEventFlags(0)), Modifiers::empty());
    }

    #[test]
    fn fn_modifier() {
        assert_eq!(
            get_modifiers(CGEventFlags(NX_DEVICEFNKEYMASK)),
            Modifiers::FN
        );
    }

    #[test]
    fn single_left_modifier() {
        assert_eq!(
            get_modifiers(CGEventFlags(NX_DEVICELALTKEYMASK)),
            Modifiers::LALT
        );
        assert_eq!(
            get_modifiers(CGEventFlags(NX_DEVICELSHIFTKEYMASK)),
            Modifiers::LSHIFT
        );
        assert_eq!(
            get_modifiers(CGEventFlags(NX_DEVICELCMDKEYMASK)),
            Modifiers::LCMD
        );
        assert_eq!(
            get_modifiers(CGEventFlags(NX_DEVICELCTLKEYMASK)),
            Modifiers::LCTRL
        );
    }

    #[test]
    fn single_right_modifier() {
        assert_eq!(
            get_modifiers(CGEventFlags(NX_DEVICERALTKEYMASK)),
            Modifiers::RALT
        );
        assert_eq!(
            get_modifiers(CGEventFlags(NX_DEVICERSHIFTKEYMASK)),
            Modifiers::RSHIFT
        );
        assert_eq!(
            get_modifiers(CGEventFlags(NX_DEVICERCMDKEYMASK)),
            Modifiers::RCMD
        );
        assert_eq!(
            get_modifiers(CGEventFlags(NX_DEVICERCTLKEYMASK)),
            Modifiers::RCTRL
        );
    }

    #[test]
    fn both_sides_of_same_modifier() {
        let flags = NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK;
        assert_eq!(get_modifiers(CGEventFlags(flags)), Modifiers::ALT);
    }

    #[test]
    fn multiple_different_modifiers() {
        let flags = NX_DEVICELCTLKEYMASK | NX_DEVICELALTKEYMASK;
        assert_eq!(
            get_modifiers(CGEventFlags(flags)),
            Modifiers::LCTRL | Modifiers::LALT
        );
    }

    #[test]
    fn mixed_sides_across_groups() {
        let flags = NX_DEVICELCMDKEYMASK | NX_DEVICERALTKEYMASK | NX_DEVICERSHIFTKEYMASK;
        assert_eq!(
            get_modifiers(CGEventFlags(flags)),
            Modifiers::LCMD | Modifiers::RALT | Modifiers::RSHIFT
        );
    }

    #[test]
    fn device_independent_flags_ignored() {
        let generic_alt: u64 = 0x0008_0000;
        assert_eq!(get_modifiers(CGEventFlags(generic_alt)), Modifiers::empty());
    }

    #[test]
    fn shared_mouse_alt_scroll_matches_generic_binding() {
        // Deskflow uses the group flag for scroll events from Windows Alt.
        let modifiers = get_event_modifiers(CGEventFlags(0x2008_0000));
        assert!(Modifiers::ALT.matches(modifiers));
        // The event does not identify a side. Do not select one.
        assert!(!Modifiers::LALT.matches(modifiers));
        assert!(!Modifiers::RALT.matches(modifiers));
    }

    #[test]
    fn shortcut_and_command_click_accept_group_only_modifier_events() {
        let flags = CGEventFlags(CGEventFlags::MaskControl.0 | CGEventFlags::MaskAlternate.0);
        let modifiers = get_event_modifiers(flags);
        assert!((Modifiers::CTRL | Modifiers::ALT).matches(modifiers));
        assert!(!(Modifiers::LCTRL | Modifiers::LALT).matches(modifiers));
        assert!(!Modifiers::ALT.matches(modifiers));
        assert!(get_event_modifiers(CGEventFlags::MaskCommand).intersects(Modifiers::CMD));
    }

    #[test]
    fn shared_mouse_extra_modifier_does_not_trigger_alt_scroll() {
        let modifiers = get_event_modifiers(CGEventFlags(0x200c_0000));
        assert!(!Modifiers::ALT.matches(modifiers));
        assert!((Modifiers::ALT | Modifiers::CTRL).matches(modifiers));
    }

    #[test]
    fn physical_scroll_keeps_the_reported_modifier_side() {
        let modifiers = get_event_modifiers(CGEventFlags(0x0008_0000 | NX_DEVICERALTKEYMASK));
        assert!(Modifiers::ALT.matches(modifiers));
        assert!(Modifiers::RALT.matches(modifiers));
        assert!(!Modifiers::LALT.matches(modifiers));
    }

    #[test]
    fn ordinary_scroll_does_not_trigger_alt_scroll() {
        assert!(!Modifiers::ALT.matches(get_event_modifiers(CGEventFlags(0x2000_0000))));
    }

    #[test]
    fn shared_mouse_scroll_supports_other_modifier_groups() {
        for (group, flag) in [
            (Modifiers::SHIFT, 0x0002_0000),
            (Modifiers::CTRL, 0x0004_0000),
            (Modifiers::CMD, 0x0010_0000),
        ] {
            assert!(group.matches(get_event_modifiers(CGEventFlags(flag))));
        }
    }

    #[test]
    fn secondary_fn_flag_is_not_ignored() {
        // Ensure we don't accidentally filter out the fn mask as "device independent"
        assert_eq!(
            get_modifiers(CGEventFlags(NX_DEVICEFNKEYMASK)),
            Modifiers::FN
        );
    }

    #[test]
    fn only_intercepts_the_explicitly_configured_gesture() {
        assert!(!gesture_should_intercept(None, 3));
        assert!(!gesture_should_intercept(Some(2), 2));
        assert!(gesture_should_intercept(Some(3), 3));
        assert!(!gesture_should_intercept(Some(4), 3));
        assert!(gesture_should_intercept(Some(4), 4));
    }
}

#[cfg(test)]
mod overview_tests {
    use super::*;
    #[test]
    fn overview_release_is_sent_once_and_contact_changes_cancel_momentum() {
        let (sender, receiver) = EventSender::new();
        let mut handler = InputHandler::new(sender, Config::default());
        handler.overview_contact_active = true;
        handler.overview_scroll_owned = true;
        handler.end_overview_contact(true, false);
        assert!(matches!(
            receiver.try_recv().unwrap(),
            Event::OverviewPanEnd { cancelled: false }
        ));
        assert!(
            handler.overview_scroll_owned,
            "The duplicate native momentum tail remains owned"
        );
        handler.end_overview_contact(true, false);
        assert!(receiver.try_recv().is_err());
        handler.overview_contact_active = true;
        handler.end_overview_contact(true, true);
        assert!(matches!(
            receiver.try_recv().unwrap(),
            Event::OverviewPanEnd { cancelled: true }
        ));
        handler.overview_contact_active = true;
        handler.end_overview_contact(false, false);
        assert!(
            receiver.try_recv().is_err(),
            "Closed overview cannot receive a stale release"
        );
    }
    #[test]
    fn three_finger_overview_pans_are_free_and_do_not_scroll_the_native_ribbon() {
        for reversed in [false, true] {
            let (sender, receiver) = EventSender::new();
            let direction = if reversed { "Reversed" } else { "Natural" };
            let config = Config::try_from(format!("[swipe]\nribbon_overview = true\nthree_finger_paging = true\nsensitivity = 1.0\n[swipe.gesture]\ndirection = '{direction}'\n").as_str()).unwrap();
            let mut handler = InputHandler::new(sender, config);
            for _ in 0..3 {
                assert!(handler.handle_gesture_delta(&[0.005; 3], &[0.0; 3], 3, true));
            }
            assert!(matches!(
                receiver.try_recv().unwrap(),
                Event::OverviewPanBegin
            ));
            let first = receiver.try_recv().unwrap();
            assert!(
                matches!(first, Event::OverviewPan { delta } if (delta - if reversed { -0.045 } else { 0.045 }).abs() < 0.0001)
            );
            assert!(handler.handle_gesture_delta(&[-0.01; 3], &[0.0; 3], 3, true));
            assert!(
                matches!(receiver.try_recv().unwrap(), Event::OverviewPan { delta } if (delta - if reversed { 0.03 } else { -0.03 }).abs() < 0.0001)
            );
            assert!(
                receiver.try_recv().is_err(),
                "No native ribbon movement, paging or focus event is emitted"
            );
        }
    }
    #[test]
    fn upward_swipe_accumulates_and_fires_once() {
        let mut swipe = OverviewSwipe::default();
        assert!(!swipe.advance(0.001, -0.02));
        assert!(swipe.advance(0.001, -0.02));
        assert!(!swipe.advance(0.0, -0.2));
    }
    #[test]
    fn horizontal_or_downward_gestures_do_not_open_overview() {
        let mut horizontal = OverviewSwipe::default();
        assert!(!horizontal.advance(0.03, -0.002));
        assert!(!horizontal.advance(0.0, -0.3));
        let mut down = OverviewSwipe::default();
        assert!(down.action(0.001, 0.05, false).is_none());
        assert!(down.axis == OverviewAxis::Down);
    }
    #[test]
    fn downward_swipe_accepts_once_only_while_overview_is_active() {
        let mut swipe = OverviewSwipe::default();
        assert!(swipe.action(0.001, 0.02, true).is_none());
        assert_eq!(
            swipe.action(0.001, 0.02, true),
            Some(OverviewCommand::Accept)
        );
        assert!(swipe.action(0.0, 0.3, true).is_none());
        assert!(
            swipe.action(0.0, -0.4, false).is_none(),
            "A reversing tail cannot reopen the overview"
        );
        let mut outside = OverviewSwipe::default();
        assert!(outside.action(0.0, 0.05, false).is_none());
        let mut up = OverviewSwipe::default();
        assert_eq!(up.action(0.0, -0.05, false), Some(OverviewCommand::Show));
    }
}

#[cfg(test)]
mod dock_overview_tests {
    use super::*;
    #[test]
    fn decodes_native_dock_control_fields_and_owns_tail_after_raw_lift() {
        let (sender, _) = EventSender::new();
        let config = Config::try_from("[swipe]\nribbon_overview = true\n").expect("config");
        let mut handler = InputHandler::new(sender, config);
        handler.last_overview_swipe = Some((Instant::now(), OverviewAxis::Up));
        let event = CGEvent::new(None).expect("local packet, never posted");
        CGEvent::set_type(Some(&event), CGEventType(DOCK_CONTROL_EVENT));
        for (field, value) in [(110, 23.0), (123, 2.0), (124, 0.4), (132, 1.0)] {
            CGEvent::set_double_value_field(Some(&event), CGEventField(field), value);
        }
        assert!(handler.handle_dock_swipe(&event));
        handler.finger_position = None;
        handler.overview_swipe = OverviewSwipe::default();
        handler.last_overview_swipe = None;
        for phase in [2.0, 4.0, 4.0] {
            CGEvent::set_double_value_field(Some(&event), CGEventField(132), phase);
            assert!(handler.handle_dock_swipe(&event));
        }
        CGEvent::set_double_value_field(Some(&event), CGEventField(123), 1.0);
        assert!(!handler.handle_dock_swipe(&event));
    }
    #[test]
    fn dismissal_owns_downward_dock_packets_after_the_panel_has_closed() {
        let (sender, _) = EventSender::new();
        let config = Config::try_from("[swipe]\nribbon_overview = true\n").expect("config");
        let mut handler = InputHandler::new(sender, config);
        handler.last_overview_swipe = Some((Instant::now(), OverviewAxis::Down));
        let event = CGEvent::new(None).expect("local packet, never posted");
        CGEvent::set_type(Some(&event), CGEventType(DOCK_CONTROL_EVENT));
        for (field, value) in [(110, 23.0), (123, 2.0), (124, -0.4)] {
            CGEvent::set_double_value_field(Some(&event), CGEventField(field), value);
        }
        for phase in [1.0, 2.0, 4.0, 4.0] {
            CGEvent::set_double_value_field(Some(&event), CGEventField(132), phase);
            assert!(handler.handle_dock_swipe(&event));
        }
        handler.last_overview_swipe = None;
        CGEvent::set_double_value_field(Some(&event), CGEventField(132), 1.0);
        assert!(
            !handler.handle_dock_swipe(&event),
            "A fresh native downward gesture still passes through"
        );
    }

    #[test]
    fn consumes_separate_dock_begin_change_end_and_repeated_end() {
        let mut dock = DockSwipeGuard::default();
        for (progress, phase) in [(0.0, 1.0), (0.3, 2.0), (-0.01, 2.0), (0.0, 4.0), (0.0, 4.0)] {
            assert!(dock.consume(23.0, 2.0, progress, phase, true));
        }
    }
    #[test]
    fn leaves_native_unrelated_disabled_and_four_finger_gestures_alone() {
        let mut dock = DockSwipeGuard::default();
        assert!(!dock.consume(23.0, 2.0, 0.1, 1.0, false));
        assert!(!dock.consume(23.0, 1.0, 0.1, 1.0, true));
        assert!(!dock.consume(8.0, 3.0, 0.1, 1.0, true));
        assert!(!dock.consume(23.0, 2.0, -0.1, 1.0, true));
        assert!(dock.consume(23.0, 2.0, 0.1, 1.0, true));
        assert!(dock.consume(23.0, 2.0, 0.2, 4.0, false));
        assert!(!dock.consume(23.0, 2.0, 0.2, 1.0, false));
    }
}
