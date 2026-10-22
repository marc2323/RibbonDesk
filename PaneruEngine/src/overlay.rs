use std::cell::RefCell;

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::{AnyThread, DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send};
use objc2_app_kit::{
    NSBackingStoreType, NSBezierPath, NSColor, NSCompositingOperation, NSFloatingWindowLevel,
    NSFont, NSGraphicsContext, NSParagraphStyle, NSScreen, NSView, NSWindow,
    NSWindowCollectionBehavior, NSWindowStyleMask,
};
use objc2_core_foundation::CGFloat;
use objc2_foundation::{
    NSAttributedString, NSDictionary, NSMutableCopying, NSPoint, NSRect, NSSize, NSString,
};

#[derive(Debug, Clone, PartialEq)]
pub struct BorderParams {
    pub color: (f64, f64, f64),
    pub opacity: f64,
    pub width: f64,
    pub radius: f64,
}

/// Parameters for the fullscreen dim + cutout overlay.
#[derive(Debug, Clone, PartialEq)]
pub struct DimParams {
    pub opacity: f32,
    pub color: (f64, f64, f64),
    /// Focused window rect in the view's local, flipped coordinates.
    /// `None` means dim everything (no focused window).
    pub cutout: Option<NSRect>,
    pub border: Option<BorderParams>,
}

// ── DimView: fullscreen dark overlay with a transparent cutout + border ──

#[derive(Debug)]
struct DimViewIvars {
    params: RefCell<DimParams>,
}

define_class!(
    #[unsafe(super(NSView))]
    #[thread_kind = MainThreadOnly]
    #[name = "PaneruDimView"]
    #[ivars = DimViewIvars]
    #[derive(Debug)]
    struct DimView;

    impl DimView {
        #[unsafe(method(drawRect:))]
        fn draw_rect(&self, _dirty_rect: NSRect) {
            let params = self.ivars().params.borrow();
            let bounds = self.bounds();

            // Clear the previous outline when reusing the view after a resize.
            if let Some(ctx) = NSGraphicsContext::currentContext() {
                ctx.setCompositingOperation(NSCompositingOperation::Clear);
                NSBezierPath::fillRect(bounds);
                ctx.setCompositingOperation(NSCompositingOperation::SourceOver);
            }
            if params.opacity > 0.0 {
                let dim_color = NSColor::colorWithSRGBRed_green_blue_alpha(
                    params.color.0, params.color.1, params.color.2,
                    CGFloat::from(params.opacity),
                );
                dim_color.setFill();
                NSBezierPath::fillRect(bounds);
            }

            if let Some(cutout) = params.cutout {
                let half = params.border.as_ref().map_or(0.0, |b| b.width / 2.0);
                let radius = params.border.as_ref().map_or(0.0, |b| b.radius);
                if params.opacity > 0.0 {
                    let hole_rect = NSRect::new(
                        NSPoint::new(cutout.origin.x - half, cutout.origin.y - half),
                        NSSize::new(cutout.size.width + 2.0 * half, cutout.size.height + 2.0 * half),
                    );
                    if let Some(ctx) = NSGraphicsContext::currentContext() {
                        ctx.setCompositingOperation(NSCompositingOperation::Clear);
                        let hole = NSBezierPath::bezierPathWithRoundedRect_xRadius_yRadius(
                            hole_rect, radius, radius,
                        );
                        hole.fill();
                        ctx.setCompositingOperation(NSCompositingOperation::SourceOver);
                    }
                }
                if let Some(border) = &params.border {
                    let path = NSBezierPath::bezierPathWithRoundedRect_xRadius_yRadius(
                        cutout, radius, radius,
                    );
                    path.setLineWidth(border.width);
                    let color = NSColor::colorWithSRGBRed_green_blue_alpha(
                        border.color.0, border.color.1, border.color.2, border.opacity,
                    );
                    color.setStroke();
                    path.stroke();
                }
            }
        }

        #[unsafe(method(isFlipped))]
        fn is_flipped(&self) -> bool {
            true
        }
    }
);

impl DimView {
    fn new(mtm: MainThreadMarker, frame: NSRect, params: &DimParams) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(DimViewIvars {
            params: RefCell::new(params.clone()),
        });
        unsafe { msg_send![super(this), initWithFrame: frame] }
    }

    fn update(&self, params: &DimParams) {
        self.ivars().params.replace(params.clone());
        self.setNeedsDisplay(true);
    }
}

// ── Coordinate helpers ──────────────────────────────────────────────────

/// Convert an absolute CG screen frame (origin top-left, y-down) to Cocoa
/// screen coordinates (origin bottom-left of primary screen, y-up).
fn cg_abs_to_cocoa(frame: NSRect, primary_screen_height: f64) -> NSRect {
    let cocoa_y = primary_screen_height - frame.origin.y - frame.size.height;
    NSRect::new(NSPoint::new(frame.origin.x, cocoa_y), frame.size)
}

/// Height of the display at the global origin (the main display, whose Cocoa
/// frame origin is `(0, 0)`). The CG↔Cocoa Y-flip is anchored to this display,
/// so it must be *that* screen — `NSScreen::screens()[0]` is NOT reliably the
/// main display, and using the wrong one offsets the overlay (and, when
/// displays are stacked, lands it on the wrong monitor).
fn primary_screen_height(mtm: MainThreadMarker) -> f64 {
    let screens = NSScreen::screens(mtm);
    let mut fallback = 0.0;
    let mut first = true;
    for screen in &screens {
        let frame = screen.frame();
        if first {
            fallback = frame.size.height;
            first = false;
        }
        if frame.origin.x == 0.0 && frame.origin.y == 0.0 {
            return frame.size.height;
        }
    }
    fallback
}

/// Do two Cocoa rects overlap? Used to decide which displays a focused window
/// touches (a window straddling a seam touches both).
fn rects_intersect(a: NSRect, b: NSRect) -> bool {
    a.origin.x < b.origin.x + b.size.width
        && b.origin.x < a.origin.x + a.size.width
        && a.origin.y < b.origin.y + b.size.height
        && b.origin.y < a.origin.y + a.size.height
}

// ── Overlay window factory ──────────────────────────────────────────────

fn make_overlay_window(mtm: MainThreadMarker, cocoa_frame: NSRect) -> Retained<NSWindow> {
    let window = unsafe {
        NSWindow::initWithContentRect_styleMask_backing_defer(
            NSWindow::alloc(mtm),
            cocoa_frame,
            NSWindowStyleMask::Borderless,
            NSBackingStoreType::Buffered,
            false,
        )
    };
    window.setOpaque(false);
    window.setBackgroundColor(Some(&NSColor::clearColor()));
    window.setIgnoresMouseEvents(true);
    window.setHasShadow(false);
    window.setLevel(NSFloatingWindowLevel);
    window.setCollectionBehavior(
        NSWindowCollectionBehavior::Transient
            | NSWindowCollectionBehavior::IgnoresCycle
            | NSWindowCollectionBehavior::CanJoinAllSpaces
            | NSWindowCollectionBehavior::Stationary
            | NSWindowCollectionBehavior::FullScreenNone,
    );

    window
}
// ── OverlayManager ──────────────────────────────────────────────────────

/// Desired overlay geometry, calculated without any `AppKit` calls.
#[derive(Debug, Clone, PartialEq)]
struct OverlayTarget {
    frame: NSRect,
    params: DimParams,
}

/// Clip each settled outline to its display, including oversized windows.
fn overlay_target(
    screen: NSRect,
    focused_cocoa: Option<NSRect>,
    opacity: f32,
    color: (f64, f64, f64),
    border: Option<&BorderParams>,
) -> Option<OverlayTarget> {
    let frame = if opacity > 0.0 {
        screen
    } else {
        let focused = focused_cocoa?;
        let margin = border.filter(|b| b.width > 0.0 && b.opacity > 0.0)?.width / 2.0 + 1.0;
        let full_frame = NSRect::new(
            NSPoint::new(focused.origin.x - margin, focused.origin.y - margin),
            NSSize::new(
                focused.size.width + 2.0 * margin,
                focused.size.height + 2.0 * margin,
            ),
        );
        if !rects_intersect(full_frame, screen) {
            return None;
        }
        let left = (focused.origin.x - margin).max(screen.origin.x);
        let bottom = (focused.origin.y - margin).max(screen.origin.y);
        let right = (focused.origin.x + focused.size.width + margin)
            .min(screen.origin.x + screen.size.width);
        let top = (focused.origin.y + focused.size.height + margin)
            .min(screen.origin.y + screen.size.height);
        if right <= left || top <= bottom {
            return None;
        }
        NSRect::new(
            NSPoint::new(left, bottom),
            NSSize::new(right - left, top - bottom),
        )
    };
    let cutout = focused_cocoa
        .filter(|wc| rects_intersect(*wc, frame))
        .map(|wc| {
            NSRect::new(
                NSPoint::new(
                    wc.origin.x - frame.origin.x,
                    (frame.origin.y + frame.size.height) - (wc.origin.y + wc.size.height),
                ),
                wc.size,
            )
        });
    Some(OverlayTarget {
        frame,
        params: DimParams {
            opacity,
            color,
            cutout,
            border: border.cloned(),
        },
    })
}

struct DisplayOverlay {
    window: Retained<NSWindow>,
    view: Retained<DimView>,
    target: OverlayTarget,
    visible: bool,
}

pub struct OverlayManager {
    mtm: MainThreadMarker,
    // Empty slots allocate no window or backing surface on untouched displays.
    overlays: Vec<Option<DisplayOverlay>>,
}

impl OverlayManager {
    pub fn new(mtm: MainThreadMarker) -> Self {
        Self {
            mtm,
            overlays: Vec::new(),
        }
    }

    pub fn update(
        &mut self,
        dim_opacity: f32,
        dim_color: (f64, f64, f64),
        focused_abs_cg: Option<NSRect>,
        border: Option<&BorderParams>,
    ) {
        let screen_h = primary_screen_height(self.mtm);
        let screens = NSScreen::screens(self.mtm);
        let focused_cocoa = focused_abs_cg.map(|cg| cg_abs_to_cocoa(cg, screen_h));
        if self.overlays.len() != screens.len() {
            self.remove_all();
            self.overlays.resize_with(screens.len(), || None);
        }
        for (i, screen) in (&screens).into_iter().enumerate() {
            let Some(target) = overlay_target(
                screen.frame(),
                focused_cocoa,
                dim_opacity,
                dim_color,
                border,
            ) else {
                if let Some(overlay) = &mut self.overlays[i]
                    && overlay.visible
                {
                    overlay.window.orderOut(None::<&AnyObject>);
                    overlay.visible = false;
                }
                continue;
            };
            if let Some(overlay) = &mut self.overlays[i] {
                if overlay.target.frame != target.frame {
                    overlay.window.setFrame_display(target.frame, false);
                }
                if overlay.target.params != target.params
                    || overlay.target.frame.size != target.frame.size
                {
                    overlay.view.update(&target.params);
                    // Finish painting before showing the settled outline.
                    overlay.window.displayIfNeeded();
                }
                if !overlay.visible {
                    overlay.window.orderFront(None::<&AnyObject>);
                    overlay.visible = true;
                }
                overlay.target = target;
            } else {
                let window = make_overlay_window(self.mtm, target.frame);
                let view = DimView::new(
                    self.mtm,
                    NSRect::new(NSPoint::new(0.0, 0.0), target.frame.size),
                    &target.params,
                );
                window.setContentView(Some(&view));
                window.orderFront(None::<&AnyObject>);
                self.overlays[i] = Some(DisplayOverlay {
                    window,
                    view,
                    target,
                    visible: true,
                });
            }
        }
    }

    pub fn remove_all(&mut self) {
        for overlay in self.overlays.drain(..).flatten() {
            overlay.window.orderOut(None::<&AnyObject>);
        }
    }

    pub fn hide_all(&mut self) {
        for overlay in self.overlays.iter_mut().flatten() {
            if overlay.visible {
                overlay.window.orderOut(None::<&AnyObject>);
                overlay.visible = false;
            }
        }
    }
}

// ── FlashMessage ────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
struct FlashMessageViewIvars {
    opacity: f32,
    message: Retained<NSString>,
    is_badge: bool,
}

define_class!(
    #[unsafe(super(NSView))]
    #[thread_kind = MainThreadOnly]
    #[name = "PaneruFlashMessageView"]
    #[ivars = FlashMessageViewIvars]
    #[derive(Debug)]
    struct FlashMessageView;

    impl FlashMessageView {
        #[unsafe(method(drawRect:))]
        fn draw_rect(&self, _dirty_rect: NSRect) {
            let ivars = self.ivars();
            let bounds = self.bounds();
            let is_badge = ivars.is_badge;

            // 1. Draw semi-transparent bezel
            let bezel_color = NSColor::colorWithSRGBRed_green_blue_alpha(
                0.12, 0.12, 0.12,
                CGFloat::from(ivars.opacity * 0.88),
            );
            bezel_color.setFill();
            let radius = if is_badge {
                24.0
            } else {
                bounds.size.height / 2.0
            };
            let path = NSBezierPath::bezierPathWithRoundedRect_xRadius_yRadius(
                bounds, radius, radius,
            );
            path.fill();

            // Draw subtle border for contrast
            let border_color = NSColor::colorWithSRGBRed_green_blue_alpha(
                1.0, 1.0, 1.0,
                CGFloat::from(ivars.opacity * 0.15),
            );
            border_color.setStroke();
            path.setLineWidth(1.0);
            path.stroke();

            // 2. Draw text
            let font = if is_badge {
                NSFont::boldSystemFontOfSize(bounds.size.height * 0.62)
            } else {
                NSFont::systemFontOfSize(30.0)
            };
            let color = NSColor::colorWithSRGBRed_green_blue_alpha(
                1.0, 1.0, 1.0,
                CGFloat::from(ivars.opacity * 0.95),
            );

            let paragraph_style = unsafe {
                let style = NSParagraphStyle::defaultParagraphStyle().mutableCopy();
                let _: () = msg_send![&style, setAlignment: 1isize]; // Center (NSTextAlignmentCenter = 1)
                let _: () = msg_send![&style, setLineBreakMode: 4isize]; // NSLineBreakByTruncatingTail = 4
                style
            };

            let attr_str: Retained<NSAttributedString> = unsafe {
                let font_key = NSString::from_str("NSFont");
                let color_key = NSString::from_str("NSColor");
                let para_key = NSString::from_str("NSParagraphStyle");

                let keys = [&*font_key, &*color_key, &*para_key];
                let objects = [
                    &*font as &AnyObject,
                    &*color as &AnyObject,
                    &*paragraph_style as &AnyObject,
                ];

                let attributes = NSDictionary::from_slices(&keys, &objects);
                let alloc = NSAttributedString::alloc();
                msg_send![alloc, initWithString: &*ivars.message, attributes: &*attributes]
            };

            let text_size: NSSize = unsafe { msg_send![&attr_str, size] };

            let text_rect = if is_badge {
                NSRect::new(
                    NSPoint::new(
                        bounds.origin.x + (bounds.size.width - text_size.width) / 2.0,
                        bounds.origin.y + (bounds.size.height - text_size.height) / 2.0,
                    ),
                    text_size,
                )
            } else {
                let h_pad = 24.0;
                let available_width = (bounds.size.width - (2.0 * h_pad)).max(1.0);
                NSRect::new(
                    NSPoint::new(
                        bounds.origin.x + h_pad,
                        bounds.origin.y + (bounds.size.height - text_size.height) / 2.0,
                    ),
                    NSSize::new(available_width, text_size.height),
                )
            };

            unsafe {
                let _: () = msg_send![&attr_str, drawInRect: text_rect];
            };
        }
    }
);

impl FlashMessageView {
    fn new(
        mtm: MainThreadMarker,
        frame: NSRect,
        message: &str,
        opacity: f32,
        is_badge: bool,
    ) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(FlashMessageViewIvars {
            opacity,
            message: NSString::from_str(message),
            is_badge,
        });
        unsafe { msg_send![super(this), initWithFrame: frame] }
    }
}

pub struct FlashMessageManager {
    mtm: MainThreadMarker,
    window: Option<Retained<NSWindow>>,
}

impl FlashMessageManager {
    pub fn new(mtm: MainThreadMarker) -> Self {
        Self { mtm, window: None }
    }

    #[allow(clippy::cast_precision_loss)]
    pub fn show(&mut self, message: &str, opacity: f32, top_right_abs_cg: NSPoint) {
        let is_badge = message.chars().count() <= 2;
        let screen_h = primary_screen_height(self.mtm);

        let size = if is_badge {
            NSSize::new(150.0, 150.0)
        } else {
            let font = NSFont::systemFontOfSize(30.0);
            let font_key = NSString::from_str("NSFont");
            let keys = [&*font_key];
            let objects = [&*font as &AnyObject];
            let attributes = NSDictionary::from_slices(&keys, &objects);
            let msg_ns = NSString::from_str(message);
            let attr_str: Retained<NSAttributedString> = unsafe {
                let alloc = NSAttributedString::alloc();
                msg_send![alloc, initWithString: &*msg_ns, attributes: &*attributes]
            };
            let text_size: NSSize = unsafe { msg_send![&attr_str, size] };
            let horizontal_padding = 48.0;
            let max_width = 780.0;
            let min_width = 140.0;
            let width = (text_size.width + horizontal_padding).clamp(min_width, max_width);
            NSSize::new(width, 64.0)
        };

        let padding = 20.0;

        let cocoa_origin_x = top_right_abs_cg.x - size.width - padding;
        let cocoa_origin_y = screen_h - (top_right_abs_cg.y + size.height + padding);

        let frame = NSRect::new(NSPoint::new(cocoa_origin_x, cocoa_origin_y), size);

        if let Some(window) = &self.window {
            let view = FlashMessageView::new(
                self.mtm,
                NSRect::new(NSPoint::new(0.0, 0.0), size),
                message,
                opacity,
                is_badge,
            );
            window.setContentView(Some(&view));
            window.setFrame_display(frame, true);
            window.orderFront(None::<&AnyObject>);
        } else {
            let window = make_overlay_window(self.mtm, frame);
            window.setLevel(NSFloatingWindowLevel + 1);
            let view = FlashMessageView::new(
                self.mtm,
                NSRect::new(NSPoint::new(0.0, 0.0), size),
                message,
                opacity,
                is_badge,
            );
            window.setContentView(Some(&view));
            window.orderFront(None::<&AnyObject>);
            self.window = Some(window);
        }
    }

    pub fn remove(&mut self) {
        if let Some(window) = self.window.take() {
            window.orderOut(None::<&AnyObject>);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rect(x: f64, y: f64, w: f64, h: f64) -> NSRect {
        NSRect::new(NSPoint::new(x, y), NSSize::new(w, h))
    }

    fn border() -> BorderParams {
        BorderParams {
            color: (0.2, 0.53, 0.62),
            opacity: 1.0,
            width: 2.0,
            radius: 10.0,
        }
    }

    #[test]
    fn border_only_uses_a_compact_surface_and_local_coordinates() {
        let target = overlay_target(
            rect(0.0, 0.0, 1920.0, 1080.0),
            Some(rect(100.0, 200.0, 500.0, 400.0)),
            0.0,
            (0.0, 0.0, 0.0),
            Some(&border()),
        )
        .unwrap();
        assert_eq!(target.frame, rect(98.0, 198.0, 504.0, 404.0));
        assert_eq!(target.params.cutout, Some(rect(2.0, 2.0, 500.0, 400.0)));
    }

    #[test]
    fn moving_without_resizing_reuses_the_same_drawing() {
        let screen = rect(0.0, 0.0, 1920.0, 1080.0);
        let first = overlay_target(
            screen,
            Some(rect(100.0, 200.0, 500.0, 400.0)),
            0.0,
            (0.0, 0.0, 0.0),
            Some(&border()),
        )
        .unwrap();
        let moved = overlay_target(
            screen,
            Some(rect(500.0, 300.0, 500.0, 400.0)),
            0.0,
            (0.0, 0.0, 0.0),
            Some(&border()),
        )
        .unwrap();
        assert_ne!(first.frame.origin, moved.frame.origin);
        assert_eq!(first.frame.size, moved.frame.size);
        assert_eq!(
            first.params, moved.params,
            "move changes only native window origin, with no view redraw"
        );
    }

    #[test]
    fn untouched_displays_and_missing_focus_allocate_no_border_surface() {
        let screen = rect(0.0, 0.0, 1920.0, 1080.0);
        assert!(overlay_target(screen, None, 0.0, (0.0, 0.0, 0.0), Some(&border())).is_none());
        assert!(
            overlay_target(
                screen,
                Some(rect(-800.0, 0.0, 500.0, 400.0)),
                0.0,
                (0.0, 0.0, 0.0),
                Some(&border())
            )
            .is_none()
        );
        assert!(
            overlay_target(
                screen,
                Some(rect(100.0, 200.0, 500.0, 400.0)),
                0.0,
                (0.0, 0.0, 0.0),
                None
            )
            .is_none()
        );
    }

    #[test]
    fn spanning_border_is_clipped_to_each_display() {
        let focused = Some(rect(-200.0, 100.0, 500.0, 400.0));
        let left = overlay_target(
            rect(-1920.0, 0.0, 1920.0, 1080.0),
            focused,
            0.0,
            (0.0, 0.0, 0.0),
            Some(&border()),
        )
        .unwrap();
        let right = overlay_target(
            rect(0.0, 0.0, 1920.0, 1080.0),
            focused,
            0.0,
            (0.0, 0.0, 0.0),
            Some(&border()),
        )
        .unwrap();
        assert_eq!(left.frame, rect(-202.0, 98.0, 202.0, 404.0));
        assert_eq!(right.frame, rect(0.0, 98.0, 302.0, 404.0));
        assert_eq!(right.params.cutout, Some(rect(-200.0, 2.0, 500.0, 400.0)));
    }

    #[test]
    fn dimming_retains_full_display_coverage_and_flips_y() {
        let screen = rect(0.0, 0.0, 1920.0, 1080.0);
        let focused = cg_abs_to_cocoa(rect(100.0, 50.0, 500.0, 400.0), 1080.0);
        let target =
            overlay_target(screen, Some(focused), 0.2, (0.0, 0.0, 0.0), Some(&border())).unwrap();
        assert_eq!(target.frame, screen);
        assert_eq!(target.params.cutout, Some(rect(100.0, 50.0, 500.0, 400.0)));
    }
}
