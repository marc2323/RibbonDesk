//! Waiting, without a thread, for a full port to have room.
//!
//! A Mach port holds few messages before a send to it blocks -- five by
//! default, fewer for some ports -- so a subscriber that stops reading for an
//! instant backs its sender up quickly. `EVFILT_MACHPORT` reports *arrivals*
//! only, so the kqueue reactor that serves [`crate::Receiver`] cannot answer
//! "is there room to send".
//!
//! What can is `MACH_NOTIFY_SEND_POSSIBLE`: ask the kernel to send *us* a
//! message when the destination becomes sendable again. That message arrives on
//! a port of our own, which the reactor **can** watch — so the wait becomes an
//! ordinary `await` on a receive, and the thread that used to park in
//! `mach_msg` is not needed at all.
//!
//! The fast path never comes here. A send is tried first and almost always
//! succeeds; this is only what happens when it does not.

use crate::error::{Error, Result};
use crate::reactor::Interest;
use crate::rights::RecvRight;
use mach2::kern_return::{KERN_SUCCESS, kern_return_t};
use mach2::mach_port::mach_port_deallocate;
use mach2::message::{MACH_MSG_TYPE_MAKE_SEND_ONCE, mach_msg_id_t, mach_msg_type_name_t};
use mach2::port::{MACH_PORT_NULL, mach_port_name_t, mach_port_t};
use mach2::traps::mach_task_self;

// `mach_port_request_notification`, which `mach2` does not bind.
//
// Cross-checked against `<mach/mach_port.h>`: the task, the name the
// notification is about, which notification, the sync value, where to deliver
// it, how that delivery right is to be treated, and an out-parameter for
// whatever registration it replaced.
unsafe extern "C" {
    fn mach_port_request_notification(
        task: mach_port_t,
        name: mach_port_name_t,
        variant: mach_msg_id_t,
        sync: mach2::port::mach_port_mscount_t,
        notify: mach_port_t,
        notify_poly: mach_msg_type_name_t,
        previous: *mut mach_port_t,
    ) -> kern_return_t;
}

/// Asks the kernel to say when nobody can send to `port` any more.
///
/// A subscription channel is a receive right this process keeps and a *send*
/// right the peer holds. Unlike the send-once right a reply port hands out,
/// a plain send right vanishing produces nothing on its own — so a drain
/// parked in [`crate::msg::recv`] on a channel whose peer has died waits for
/// a message that cannot come. Hence the orphaned daemons: the peer exits,
/// its send right is destroyed with it, and the receiver never learns.
///
/// The notification is delivered to `port` itself, so it arrives in the same
/// queue the drain is already parked on and needs no second port to watch.
/// [`crate::msg::parse`] turns it into [`Error::PeerGone`].
///
/// # Errors
///
/// The kernel's status if it will not register the notification.
pub(crate) fn watch_no_senders(port: &RecvRight) -> Result<()> {
    let mut previous: mach_port_t = MACH_PORT_NULL;

    // `sync` of 1 rather than 0, and the difference is the whole race: the
    // caller has already handed the peer a send right by the time it gets
    // here, so the make-send count is at least one. Armed against that, a
    // peer that died in between is reported at once instead of being waited
    // for for ever, while a live one leaves this pending. With 0 it would
    // fire immediately every time, which is a spurious `PeerGone` on every
    // healthy subscription.
    //
    // SAFETY: `port` is a receive right this process owns, and `previous` is
    // a valid out-pointer.
    let status = unsafe {
        mach_port_request_notification(
            mach_task_self(),
            port.as_raw(),
            mach2::notify::MACH_NOTIFY_NO_SENDERS,
            1,
            port.as_raw(),
            MACH_MSG_TYPE_MAKE_SEND_ONCE,
            &raw mut previous,
        )
    };
    if status != KERN_SUCCESS {
        return Err(Error::from_kern(status));
    }

    // As in `Sendable::request`: one request per name, and a replaced one
    // hands its send-once right back here rather than firing.
    if previous != MACH_PORT_NULL {
        // SAFETY: `previous` was just filled in above -- a send-once right
        // this task now owns.
        unsafe { mach_port_deallocate(mach_task_self(), previous) };
    }
    Ok(())
}

/// A pending "there is room now" notification for one destination.
///
/// Holds the port the kernel will answer on, and that port's registration with
/// the reactor. Dropping it drops both, which is what makes an abandoned send
/// leave nothing behind.
pub(crate) struct Sendable {
    /// Where the kernel delivers the notification.
    port: RecvRight,
    /// That port's place in the reactor's waker table.
    interest: Interest,
}

impl Sendable {
    /// Asks the kernel to say when `destination` can take a message.
    ///
    /// # Errors
    ///
    /// The kernel's status if it will not register the notification — most
    /// often because the destination is already dead, which a caller should
    /// treat as [`Error::PeerGone`].
    pub(crate) fn request(destination: mach_port_t) -> Result<Self> {
        let port = RecvRight::alloc()?;
        let mut previous: mach_port_t = MACH_PORT_NULL;

        // `sync` of 1: arm it against the queue as it is now, so a slot freed
        // between the failed send and this call is still reported rather than
        // waited for for ever.
        //
        // SAFETY: `destination` is a live send right the caller holds, `port`
        // is a receive right this owns, and `previous` is a valid out-pointer.
        let status = unsafe {
            mach_port_request_notification(
                mach_task_self(),
                destination,
                mach2::notify::MACH_NOTIFY_SEND_POSSIBLE,
                1,
                port.as_raw(),
                MACH_MSG_TYPE_MAKE_SEND_ONCE,
                &raw mut previous,
            )
        };
        if status != KERN_SUCCESS {
            return Err(Error::from_kern(status));
        }

        // The kernel keeps one such request per destination name; registering
        // a second replaces the first and hands back its send-once right here
        // rather than firing it. Nothing calls `send` twice concurrently on
        // one subscriber, so this should be null, but releasing it if it
        // isn't is what keeps a caller who breaks that rule from leaking a
        // right instead of just losing a wakeup.
        if previous != MACH_PORT_NULL {
            // SAFETY: `previous` was just filled in by the call above -- a
            // send-once right this task now owns.
            unsafe { mach_port_deallocate(mach_task_self(), previous) };
        }

        let interest = Interest::new(&port);
        Ok(Self { port, interest })
    }

    /// The registration to await on.
    pub(crate) const fn interest(&self) -> &Interest {
        &self.interest
    }

    /// Takes the notification off the port once it has arrived.
    ///
    /// The message itself says nothing this caller needs — its arrival *is* the
    /// answer — so it is received and dropped without being parsed as one of
    /// this protocol's own message shapes.
    pub(crate) fn consume(&self) {
        let _ = crate::msg::try_recv_signal(&self.port);
    }
}

/// Waits for one `MACH_NOTIFY_SEND_POSSIBLE` to arrive.
///
/// A future rather than a method so the registration is armed on the first poll
/// with the *executor's* waker, and disarmed if the caller gives up.
pub(crate) struct Ready<'a> {
    sendable: &'a Sendable,
}

impl<'a> Ready<'a> {
    pub(crate) const fn new(sendable: &'a Sendable) -> Self {
        Self { sendable }
    }
}

impl std::future::Future for Ready<'_> {
    type Output = ();

    fn poll(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<()> {
        // The notification may already be sitting there: the destination can
        // drain between the failed send and this poll, and a one-shot that has
        // already fired never fires again. `try_recv_signal`, not `try_recv`:
        // this message is a plain kernel notification, not one of this
        // protocol's own shapes, and `try_recv` would reject it as malformed
        // after already having drained it -- stranding the wakeup for good.
        if crate::msg::try_recv_signal(&self.sendable.port).is_ok() {
            return std::task::Poll::Ready(());
        }
        match self.sendable.interest().arm(cx.waker()) {
            Ok(()) => {
                // The notification may have landed between the check above and
                // `arm` registering with the reactor -- `EV_ADD` only reports
                // messages that arrive *after* it runs, so one that beat it
                // here would otherwise wait for a wakeup that already happened
                // and never comes again. Mirrors `poll_recv`'s retry-after-arm.
                if crate::msg::try_recv_signal(&self.sendable.port).is_ok() {
                    std::task::Poll::Ready(())
                } else {
                    std::task::Poll::Pending
                }
            }
            // The reactor is unusable. Reporting ready sends the caller back
            // around its loop, where the send itself reports the real error
            // rather than this one being swallowed here.
            Err(_) => std::task::Poll::Ready(()),
        }
    }
}

#[cfg(test)]
mod no_senders_tests {
    use super::watch_no_senders;
    use crate::error::Error;
    use crate::rights::RecvRight;

    /// The whole point: a channel whose peer has gone must answer, not park.
    #[test]
    fn a_channel_whose_peer_vanished_reports_gone_instead_of_parking() {
        let port = RecvRight::alloc().expect("a fresh port");
        let peer = port.make_send().expect("a send right for the peer");
        watch_no_senders(&port).expect("the kernel takes the request");

        // What a peer process dying does to the right it held.
        drop(peer);

        match crate::msg::recv(&port) {
            Err(Error::PeerGone) => {}
            Ok(_) => panic!("a no-senders notification decoded as a real message"),
            Err(err) => panic!("expected PeerGone, got {err}"),
        }
    }

    /// And it must not fire while the peer is still there, or every healthy
    /// subscription would report itself dead the moment it opened.
    #[test]
    fn a_live_peer_does_not_look_gone() {
        let port = RecvRight::alloc().expect("a fresh port");
        let _peer = port.make_send().expect("a send right for the peer");
        watch_no_senders(&port).expect("the kernel takes the request");

        match crate::msg::try_recv(&port) {
            Err(Error::WouldBlock) => {}
            Ok(_) => panic!("something arrived on an idle channel"),
            Err(err) => panic!("expected an empty port, got {err}"),
        }
    }
}
