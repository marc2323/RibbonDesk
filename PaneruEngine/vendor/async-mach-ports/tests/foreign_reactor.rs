//! Somebody else's reactor servicing the port, in both of the shapes one
//! comes in.
//!
//! A reactor that only *notifies* — kqueue's `EVFILT_MACHPORT`, libdispatch's
//! `DISPATCH_SOURCE_TYPE_MACH_RECV` — leaves the message queued and this crate
//! receives it: [`Receiver::try_recv`]. A reactor that *receives* — a
//! `CFMachPort` on a `CFRunLoop` — has already done the `mach_msg` and hands
//! the message over: [`Receiver::decode_message`]. The second is the one that
//! is easy to get wrong, because `try_recv` on that route quietly answers
//! `WouldBlock` for a message that has already been taken.
//!
//! The point of both is that a caller in either position never writes a
//! `mach_msg` receive of its own, never sees the message layout, and never has
//! to release a right or an out-of-line mapping by hand.

use async_mach_ports::{Error, Receiver, RecvPort, SendPort, Sender};

mod support;
use support::Postcard;

/// A name of this test's own, so a stale bind from another run cannot collide.
fn service_name(test: &str) -> String {
    format!("com.async-mach-ports.foreign.{test}.{}", std::process::id())
}

/// Stands in for the notifier a real consumer would have -- a dispatch source,
/// a kqueue of its own. All any of them do is decide *when* to call
/// `try_recv`.
fn drain<T, C>(receiver: &Receiver<T, C>) -> Vec<T>
where
    T: serde::de::DeserializeOwned,
    C: async_mach_ports::Codec,
{
    let mut taken = Vec::new();
    loop {
        match receiver.try_recv() {
            Ok(delivery) => taken.push(delivery.value),
            Err(Error::WouldBlock) => return taken,
            Err(err) => panic!("unexpected receive failure: {err}"),
        }
    }
}

/// How many messages the kernel will hold on `port` before a send has to
/// wait.
///
/// The burst below sends from this thread, so it has to stay inside that
/// limit: one more and the send parks in the kernel waiting for a receive that
/// cannot happen until it returns. The number is the kernel's and is asked
/// for rather than assumed -- it is *not* `MACH_PORT_QLIMIT_DEFAULT`, which
/// says 5 while a freshly allocated port here answers 2. Nothing raises it:
/// the depth a service gets is the kernel's on purpose, because it is what
/// makes a client wait while a busy daemon catches up.
fn queue_limit(port: async_mach_ports::mach_port_t) -> usize {
    /// `MACH_PORT_LIMITS_INFO`, the only flavour asked for here.
    const LIMITS_INFO: i32 = 1;

    // mach2 binds neither the call nor the flavour, so the declaration is
    // written out. A consumer of this crate never needs either.
    unsafe extern "C" {
        fn mach_port_get_attributes(
            task: mach2::port::mach_port_t,
            name: mach2::port::mach_port_t,
            flavor: i32,
            info: *mut i32,
            count: *mut u32,
        ) -> mach2::kern_return::kern_return_t;
    }

    let mut qlimit: i32 = 0;
    let mut count: u32 = 1;
    // SAFETY: `MACH_PORT_LIMITS_INFO` is one word wide, which is what `count`
    // claims of `qlimit`, and `port` names a receive right this task owns.
    let rc = unsafe {
        mach_port_get_attributes(
            mach2::traps::mach_task_self(),
            port,
            LIMITS_INFO,
            &raw mut qlimit,
            &raw mut count,
        )
    };
    assert_eq!(rc, mach2::kern_return::KERN_SUCCESS, "get the queue limit");
    usize::try_from(qlimit).expect("a queue limit is not negative")
}

/// One `mach_msg` receive done by hand, standing in for the one `CFRunLoop`
/// does before it calls a `CFMachPort` callout. Nothing here looks *inside*
/// the message: it is a buffer and a length, handed straight back to the
/// crate.
fn receive_raw(port: async_mach_ports::mach_port_t) -> Vec<u8> {
    use mach2::message::{MACH_RCV_MSG, mach_msg, mach_msg_header_t};

    #[repr(C, align(8))]
    struct Buffer([u8; 1024]);

    let mut buffer = Buffer([0u8; 1024]);
    // SAFETY: the buffer is 8-aligned and as long as the size argument says.
    let rc = unsafe {
        mach_msg(
            std::ptr::addr_of_mut!(buffer).cast::<mach_msg_header_t>(),
            MACH_RCV_MSG,
            0,
            1024,
            port,
            0,
            mach2::port::MACH_PORT_NULL,
        )
    };
    assert_eq!(rc, mach2::kern_return::KERN_SUCCESS, "raw receive");

    // SAFETY: the kernel wrote a message at the start of the buffer.
    let header =
        unsafe { std::ptr::read_unaligned(std::ptr::addr_of!(buffer).cast::<mach_msg_header_t>()) };
    buffer.0[..header.msgh_size as usize].to_vec()
}

#[test]
fn try_recv_is_empty_until_something_arrives() {
    let name = service_name("empty");
    let receiver: Receiver<u32, _> = Receiver::bind(&name, Postcard).expect("bind");
    assert!(
        matches!(receiver.try_recv(), Err(Error::WouldBlock)),
        "an idle port answers WouldBlock rather than waiting"
    );
}

#[test]
fn a_notifying_reactor_receives_without_touching_the_wire_format() {
    let name = service_name("foreign");
    let receiver: Receiver<u32, _> = Receiver::bind(&name, Postcard).expect("bind");
    let sender: Sender<u32, _> = Sender::connect(&name, Postcard).expect("connect");

    sender.send_blocking(&7).expect("send");
    assert_eq!(drain(&receiver), vec![7]);

    // And again, so the port is proven reusable rather than good once.
    sender.send_blocking(&8).expect("send");
    sender.send_blocking(&9).expect("send");
    assert_eq!(drain(&receiver), vec![8, 9]);
}

#[test]
fn a_burst_drains_in_one_pass() {
    let name = service_name("burst");
    let receiver: Receiver<u32, _> = Receiver::bind(&name, Postcard).expect("bind");
    let sender: Sender<u32, _> = Sender::connect(&name, Postcard).expect("connect");

    let burst = queue_limit(receiver.as_raw_port());
    assert!(burst > 1, "a queue that holds one message tests nothing");
    for i in 0..burst {
        sender
            .send_blocking(&u32::try_from(i).expect("small"))
            .expect("send");
    }
    // What one notification is worth: everything queued behind it, taken until
    // the port says it is empty.
    let taken = drain(&receiver);
    assert_eq!(
        taken,
        (0..u32::try_from(burst).expect("small")).collect::<Vec<_>>(),
        "one drain takes the whole burst, not one message"
    );
}

/// The `CFMachPort` route: the reactor did the receive, so `try_recv` has
/// nothing left to find and the bytes it hands over are all there is.
#[test]
fn a_receiving_reactor_hands_the_message_over() {
    let name = service_name("receiving");
    let receiver: Receiver<u32, _> = Receiver::bind(&name, Postcard).expect("bind");

    let client_name = name.clone();
    let client = std::thread::spawn(move || {
        let sender: Sender<u32, _> = Sender::connect(&client_name, Postcard).expect("connect");
        sender.call_blocking::<u32>(&21).expect("call")
    });

    let message = receive_raw(receiver.as_raw_port());
    assert!(
        matches!(receiver.try_recv(), Err(Error::WouldBlock)),
        "the reactor took the message, so nothing is left queued"
    );

    // SAFETY: `message` is the message just received on this receiver's port,
    // handed here once and parsed by nothing else.
    let delivery = unsafe { receiver.decode_message(&message) }.expect("decode");
    assert_eq!(delivery.value, 21);
    delivery
        .reply
        .expect("a call asks for an answer")
        .send(&42u32)
        .expect("the reply right survived the hand-over");

    assert_eq!(client.join().expect("client"), 42);
}

/// A daemon that exits mid-request: the kernel tells the waiting client by
/// sending the send-once notification to its reply port, and that is a peer
/// that has gone rather than a message this protocol cannot read.
#[test]
fn an_abandoned_call_reports_the_peer_as_gone() {
    let name = service_name("abandoned");
    let receiver: Receiver<u32, _> = Receiver::bind(&name, Postcard).expect("bind");

    let client_name = name.clone();
    let client = std::thread::spawn(move || {
        let sender: Sender<u32, _> = Sender::connect(&client_name, Postcard).expect("connect");
        sender.call_blocking::<u32>(&1)
    });

    let delivery = receiver.recv_blocking().expect("the request");
    // Dropping the reply releases the send-once right without using it, which
    // is what a daemon exiting mid-request does.
    drop(delivery);

    assert!(
        matches!(client.join().expect("client"), Err(Error::PeerGone)),
        "an unanswered call ends as PeerGone, not as a malformed message"
    );
}
