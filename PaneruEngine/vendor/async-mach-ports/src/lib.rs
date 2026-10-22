// A published library's documentation is part of its interface, and so is the
// argument for every `unsafe` block in it. Both are lints rather than habits
// so that neither can quietly stop being true.
#![deny(missing_docs)]
#![deny(unsafe_op_in_unsafe_fn)]
#![warn(clippy::undocumented_unsafe_blocks)]

//! Typed channels between unrelated processes, over Mach ports.
//!
//! One process binds a well-known service name and holds a [`Receiver<T>`]; any
//! number of unrelated processes connect a [`Sender<T>`] to that name and send
//! it values, mirroring the shape of `std`'s channels:
//!
//! ```no_run
//! # use serde::{Serialize, Deserialize, de::DeserializeOwned};
//! # #[derive(Serialize, Deserialize)] struct Request;
//! # #[derive(Serialize, Deserialize)] struct Response;
//! # #[derive(Clone, Copy)] struct Json;
//! # impl async_mach_ports::Codec for Json {
//! #     fn encode<T: Serialize + ?Sized>(&self, v: &T) -> async_mach_ports::Result<Vec<u8>> { unimplemented!() }
//! #     fn decode<T: DeserializeOwned>(&self, b: &[u8]) -> async_mach_ports::Result<T> { unimplemented!() }
//! # }
//! # fn main() -> Result<(), async_mach_ports::Error> {
//! use async_mach_ports::{RecvPort, SendPort};
//! # futures_lite::future::block_on(async {
//! // The daemon. `Json` here is any type implementing `Codec`: the format is
//! // handed to the port, not baked into the transport.
//! let receiver = async_mach_ports::Receiver::<Request, _>::bind("com.example.service", Json)?;
//! let delivery = receiver.recv().await?;
//! if let Some(reply) = delivery.reply {
//!     reply.send(&Response)?;
//! }
//!
//! // A client, in some other process, naming the same format.
//! let sender = async_mach_ports::Sender::<Request, _>::connect("com.example.service", Json)?;
//! let response: Response = sender.call(&Request).await?;
//!
//! // The same client with no executor to run on: same names, `_blocking`.
//! let response: Response = sender.call_blocking(&Request)?;
//! # Ok(())
//! # })
//! # }
//! ```
//!
//! Operations come in async/blocking pairs (`send`/`send_blocking`, and so on)
//! on [`SendPort`] and [`RecvPort`]. [`Receiver`] also implements [`Stream`]:
//! `poll_next` attempts a non-blocking receive and, when the port is empty,
//! registers the task's waker against a process-wide kqueue watching that port
//! (`EVFILT_MACHPORT`), rather than parking a thread on `mach_msg`.
//!
//! Values cross the wire through a [`Codec`] — a serialise function and a
//! deserialise function, given to a port when it is created — which is why `T`
//! is bounded by serde's traits. This crate ships no format and depends on
//! none: which bytes go on the wire is the protocol's decision, not the
//! transport's, and a protocol that wants serde's declarative attributes
//! (`#[serde(untagged)]`, `#[serde(flatten)]`) needs a *self-describing* format
//! to get them, while one with a fixed schema may prefer a compact positional
//! one. Writing a codec is two lines over a serde format crate; see [`Codec`].
//!
//! The two ends must agree on the format, and because the codec is part of each
//! port's type, disagreeing is a compile error in any code that owns both.
//!
//! # Somebody else's reactor
//!
//! The kqueue thread is this crate's answer to "how does an executor learn a
//! port has a message", not the only one. A process that already runs a
//! `CFRunLoop`, a dispatch queue or a kqueue of its own can service the port
//! natively, and [`Receiver::as_raw_port`] hands out the name it needs to.
//! That saves the kqueue thread *and* whatever thread would have awaited the
//! stream.
//!
//! Which call comes back depends on what that reactor does when the port
//! fires, and there are two kinds:
//!
//! * one that **notifies** — kqueue's `EVFILT_MACHPORT`, libdispatch's
//!   `DISPATCH_SOURCE_TYPE_MACH_RECV` — leaves the message in the kernel's
//!   queue and says only that one is there. Call [`Receiver::try_recv`], and
//!   keep calling it until [`Error::WouldBlock`], since one notification may
//!   cover several messages.
//! * one that **receives** — `CFMachPortCreateWithPort` under a `CFRunLoop` —
//!   has already done the `mach_msg` by the time it calls back, and hands over
//!   the message it took. Call [`Receiver::decode_message`] with those bytes.
//!   [`Receiver::try_recv`] would not see that message; it is no longer
//!   queued.
//!
//! Either way it is a trade, not a free win: the other reactor is now the one
//! servicing the port, so a message it takes is one [`RecvPort::recv`] and
//! [`Stream`] never see. Take this route and the port is that consumer's to
//! service, all of it.

#[cfg(not(target_os = "macos"))]
compile_error!(
    "async-mach-ports supports macOS only: it is built on Mach ports, the bootstrap server and kqueue's EVFILT_MACHPORT."
);

/// Maximum received out-of-line payload. Checked before copying or decoding.
/// The kernel mapping is released even when an oversized message is rejected.
pub const MAX_PAYLOAD_BYTES: usize = 4 * 1024 * 1024;

pub mod bootstrap;

mod codec;
mod error;
mod msg;
mod notify;
mod reactor;
pub mod rights;

pub use codec::Codec;
pub use error::{Error, Result, Status};
pub use futures_lite::Stream;
/// A Mach port name, as the kernel and every C API spell it.
///
/// Re-exported so a host watching [`Receiver::as_raw_port`] with a reactor of
/// its own can name the type without depending on `libc` for one alias.
pub use libc::mach_port_t;
// Named only by the sealed `Inbound` supertrait; not part of the API a caller
// writes against, but it has to be reachable for that bound to typecheck.
#[doc(hidden)]
pub use reactor::Interest;
use rights::{RecvRight, SendOnceRight, SendRight};
use serde::Serialize;
use serde::de::DeserializeOwned;
use std::fmt;
use std::marker::PhantomData;
use std::pin::Pin;
use std::task::{Context, Poll};

/// Attempts a receive and, if the port is empty, arms a one-shot wakeup.
/// Trying first is required for correctness: the kqueue registration only
/// reports messages arriving after it exists, so anything already queued
/// would otherwise never wake anyone.
fn poll_recv(
    port: &RecvRight,
    interest: &Interest,
    cx: &Context<'_>,
) -> Poll<Result<msg::Incoming>> {
    match msg::try_recv(port) {
        Err(Error::WouldBlock) => {}
        other => return Poll::Ready(other),
    }

    if let Err(err) = interest.arm(cx.waker()) {
        return Poll::Ready(Err(err));
    }

    // A message may have arrived between the failed receive and the
    // registration; retrying once keeps it from being stranded.
    match msg::try_recv(port) {
        Err(Error::WouldBlock) => Poll::Pending,
        other => Poll::Ready(other),
    }
}

/// Hands a value to the kernel, yielding to the executor rather than blocking
/// if the destination's queue is momentarily full. There is no "writable"
/// event for a Mach port (`EVFILT_MACHPORT` reports arrivals only), so
/// cooperative yielding is used instead of parking a thread.
async fn send_async(
    service: &SendRight,
    payload: &[u8],
    extra_port: Option<&RecvRight>,
) -> Result<()> {
    loop {
        let message = msg::Outgoing::new(service, payload).without_waiting();
        let message = match extra_port {
            Some(port) => message.carrying(port),
            None => message,
        };
        match message.send() {
            Err(Error::WouldBlock) => futures_lite::future::yield_now().await,
            other => return other,
        }
    }
}

/// The receiving end of a service: owns the name and yields what is sent to it.
///
/// Only one process can hold this for a given name — that is what a receive
/// right means — so binding is also how a daemon claims singleton status.
pub struct Receiver<T, C> {
    port: RecvRight,
    interest: Interest,
    codec: C,
    _value: PhantomData<fn() -> T>,
}

impl<T: DeserializeOwned, C: Codec> Receiver<T, C> {
    /// Takes ownership of the service name, decoding what arrives with
    /// `codec`.
    ///
    /// Tries launchd's `MachServices` handover first and falls back to
    /// registering the name directly, so the same call works whether the process
    /// was started by `launchctl` or from a shell.
    ///
    /// # Errors
    ///
    /// Returns [`Error::AlreadyRunning`] if another process holds the name.
    pub fn bind(service: &str, codec: C) -> Result<Self> {
        let port = match bootstrap::check_in(service) {
            Ok(port) => port,
            // Not a launchd job, so publish the name ourselves.
            Err(Error::NotRunning) => bootstrap::register(service)?,
            Err(err) => return Err(err),
        };
        Ok(Self::from_port(port, codec))
    }

    fn poll_delivery(&self, cx: &Context<'_>) -> Poll<Result<Delivery<T, C>>> {
        poll_recv(&self.port, &self.interest, cx).map(|result| {
            result.and_then(|incoming| Delivery::from_incoming(incoming, &self.codec))
        })
    }

    /// Takes a message if one is already queued, without waiting.
    ///
    /// The third way to receive, beside [`RecvPort::recv`]'s future and
    /// [`RecvPort::recv_blocking`]'s parked thread. This one neither suspends
    /// nor blocks, which is what a caller driving an event loop of its own
    /// needs once something has told it the port is readable.
    ///
    /// All three end at the same receive and the same parse; they differ only
    /// in who does the waiting -- an executor, the calling thread, or a
    /// notifier outside this crate. That is the whole of the distinction, and
    /// this crate takes no view on which is right.
    ///
    /// This is for a reactor that *notifies*: kqueue's `EVFILT_MACHPORT`,
    /// libdispatch's `DISPATCH_SOURCE_TYPE_MACH_RECV`. A reactor that
    /// *receives* — `CFMachPort` under a `CFRunLoop` does — has already taken
    /// the message off the queue by the time it says so, and its consumer
    /// wants [`Self::decode_message`] instead.
    ///
    /// # Errors
    ///
    /// [`Error::WouldBlock`] when the port is empty, which is the ordinary
    /// answer for a caller that guessed early rather than a fault. Otherwise
    /// as [`RecvPort::recv`].
    pub fn try_recv(&self) -> Result<Delivery<T, C>> {
        Delivery::from_incoming(msg::try_recv(&self.port)?, &self.codec)
    }

    /// Reads a message somebody else's reactor already received on this port.
    ///
    /// `CFRunLoop` does the `mach_msg` itself for a `CFMachPort` and hands the
    /// dequeued message to its callout, so a consumer on that route never gets
    /// to call [`Self::try_recv`] for it: by the time the callout runs the
    /// message is out of the kernel's queue and only these bytes are left.
    /// This turns them back into a [`Delivery`] — the same parse the other
    /// three receives end at — so the message layout, its trailer and its
    /// out-of-line memory still never leave this crate.
    ///
    /// # Safety
    ///
    /// `message` must be a Mach message the kernel delivered on *this*
    /// receiver's port, whose rights and out-of-line memory nothing else has
    /// consumed or will consume, and it must be passed here at most once.
    /// Parsing takes ownership of both: the payload's mapping is copied out
    /// and unmapped, and a reply port becomes a [`Reply`] that will be
    /// released. Bytes that are not such a message can name a mapping this
    /// task did not receive, which is why this is `unsafe` rather than merely
    /// fallible.
    ///
    /// # Errors
    ///
    /// [`Error::Malformed`] if the bytes are not a message this protocol
    /// wrote, [`Error::PeerGone`] for the kernel's send-once notification that
    /// arrives on a reply port when the peer died holding the right, and
    /// [`Error::Decode`] if the payload is not a `T`.
    pub unsafe fn decode_message(&self, message: &[u8]) -> Result<Delivery<T, C>> {
        Delivery::from_incoming(msg::parse(message)?, &self.codec)
    }
}

impl<T, C> Receiver<T, C> {
    fn from_port(port: RecvRight, codec: C) -> Self {
        let interest = Interest::new(&port);
        Self {
            port,
            interest,
            codec,
            _value: PhantomData,
        }
    }

    /// The format this end decodes with, as it was handed to [`Self::bind`].
    pub const fn codec(&self) -> &C {
        &self.codec
    }

    /// The receive right, for a caller that wants to watch this port itself.
    ///
    /// The kqueue reactor is one way to learn a port has a message, not the
    /// only one, and not one every consumer wants: a Lua module, a library
    /// embedded in someone else's runtime, or a process already pumping a
    /// `CFRunLoop` all have a loop of their own and no use for a second
    /// thread. Any of them can watch this name.
    ///
    /// **The name is for watching, not for receiving.** The message layout,
    /// its trailer and its out-of-line memory belong to this crate, and one of
    /// two calls is what keeps them here: [`Self::try_recv`] where the watcher
    /// only notifies (kqueue `EVFILT_MACHPORT`, dispatch `MACH_RECV`), or
    /// [`Self::decode_message`] where it does the `mach_msg` itself and hands
    /// the message over (`CFMachPort`). A caller that instead calls `mach_msg`
    /// on this right owns every one of those problems, including releasing
    /// rights and unmapping payloads.
    ///
    /// Watching it and polling the [`Stream`] at the same time is a mistake
    /// either way: a receiving watcher takes the message before the stream can
    /// see it, and a notifying one races the stream for each message.
    ///
    /// The right stays owned by this [`Receiver`] -- the name is borrowed for
    /// as long as it lives, and releasing it is still this value's `Drop`.
    #[must_use]
    pub fn as_raw_port(&self) -> mach_port_t {
        self.port.as_raw()
    }
}

/// Written by hand rather than derived so that neither the message type nor the
/// codec has to be [`Debug`](fmt::Debug) for a port to be printable.
impl<T, C> fmt::Debug for Receiver<T, C> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Receiver")
            .field("port", &self.port)
            .finish_non_exhaustive()
    }
}

/// The values sent to a service, as they arrive.
///
/// The stream does not end on its own: a [`Error::Decode`] item is one bad
/// client, not the end of the service, so callers should log such an item and
/// keep polling rather than break.
impl<T: DeserializeOwned, C: Codec> Stream for Receiver<T, C> {
    type Item = Result<Delivery<T, C>>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        self.poll_delivery(cx).map(Some)
    }
}

/// One value off the wire, with whatever the sender attached to it.
///
/// The channels back carry the receiving port's codec, so an answer is encoded
/// the same way the question was decoded without the handler having to say so.
pub struct Delivery<T, C> {
    /// The decoded value.
    pub value: T,
    /// Where the answer goes, when the sender used [`Sender::call`]. A
    /// [`Sender::send`] leaves this `None`.
    pub reply: Option<Reply<C>>,
    /// The channel a [`Sender::subscribe`] asked for events on.
    pub subscriber: Option<Subscriber<C>>,
}

impl<T: DeserializeOwned, C: Codec> Delivery<T, C> {
    /// Decodes one wire message into a delivery. Shared by the polled and the
    /// blocking receive so the two cannot drift on what a message means.
    fn from_incoming(incoming: msg::Incoming, codec: &C) -> Result<Self> {
        Ok(Self {
            value: codec.decode(&incoming.payload)?,
            reply: incoming.reply.map(|right| Reply {
                right,
                codec: codec.clone(),
            }),
            subscriber: incoming.ports.into_iter().next().map(|right| Subscriber {
                right,
                codec: codec.clone(),
            }),
        })
    }
}

/// Written by hand so that only the value type, not the codec, needs to be
/// [`Debug`](fmt::Debug).
impl<T: fmt::Debug, C> fmt::Debug for Delivery<T, C> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Delivery")
            .field("value", &self.value)
            .field("reply", &self.reply)
            .field("subscriber", &self.subscriber)
            .finish()
    }
}

/// A one-shot channel back to whoever sent a value.
///
/// Consuming `self` on send matches the kernel: the underlying send-once right
/// is spent when the message goes out, so a second use could not work even if
/// the type allowed it.
pub struct Reply<C> {
    right: SendOnceRight,
    codec: C,
}

/// Written by hand so that the codec does not have to be
/// [`Debug`](fmt::Debug).
impl<C> fmt::Debug for Reply<C> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Reply")
            .field("right", &self.right)
            .finish_non_exhaustive()
    }
}

impl<C: Codec> Reply<C> {
    /// Answers the sender. Not `async`: a send-once right's queue has never
    /// been used and never will be again, so there is no full-queue case to
    /// wait on.
    ///
    /// # Errors
    ///
    /// Returns [`Error::PeerGone`] if the sender stopped waiting and exited,
    /// which is normal — a client interrupted mid-request does exactly this.
    pub fn send<R: Serialize + ?Sized>(self, value: &R) -> Result<()> {
        let payload = self.codec.encode(value)?;
        msg::reply(self.right, &payload)
    }
}

/// A lasting channel to a process that asked for events.
///
/// Unlike [`Reply`] this survives the value that delivered it: the daemon keeps
/// it and pushes to it for as long as the subscriber lives.
pub struct Subscriber<C> {
    right: SendRight,
    codec: C,
}

/// Written by hand so that the codec does not have to be
/// [`Debug`](fmt::Debug).
impl<C> fmt::Debug for Subscriber<C> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Subscriber")
            .field("right", &self.right)
            .finish_non_exhaustive()
    }
}

impl<C: Codec> Subscriber<C> {
    /// Whether the receiving port still exists. This lets bounded registries
    /// reclaim disconnected clients even when there are no events to send.
    pub fn is_alive(&self) -> bool {
        unsafe extern "C" {
            fn mach_port_type(task: mach_port_t, name: mach_port_t, kind: *mut u32) -> i32;
        }
        let mut kind = 0;
        // SAFETY: right is a live owned send/dead-name right and kind is writable.
        let status = unsafe {
            mach_port_type(
                mach2::traps::mach_task_self(),
                self.right.as_raw(),
                &raw mut kind,
            )
        };
        status == mach2::kern_return::KERN_SUCCESS
            && kind & (1 << (mach2::port::MACH_PORT_RIGHT_DEAD_NAME + 16)) == 0
    }

    /// Pushes one event, without ever waiting. Deliberately not `async`: a
    /// subscriber that has stopped reading must not be able to stall the
    /// window manager, so a full queue drops the event rather than applying
    /// backpressure.
    ///
    /// # Errors
    ///
    /// [`Error::PeerGone`] means the subscriber's process is gone and it should
    /// be dropped. [`Error::WouldBlock`] means it is alive but not keeping up;
    /// the event is lost but the subscriber should be kept.
    pub fn try_send<E: Serialize + ?Sized>(&self, value: &E) -> Result<()> {
        let payload = self.codec.encode(value)?;
        msg::Outgoing::new(&self.right, &payload)
            .without_waiting()
            .send()
    }

    /// Pushes one event, **waiting without a thread** when the subscriber has
    /// no room for it.
    ///
    /// The one to reach for. [`Self::try_send`] throws the event away when the
    /// queue is full and [`Self::send_blocking`] parks a whole thread on it;
    /// this does neither, so a caller can hold one task per subscriber instead
    /// of one thread.
    ///
    /// The fast path is `try_send` — a Mach send to a port with room does not
    /// block, so the common case never waits at all. Only a full queue reaches
    /// the slow path, which asks the kernel for `MACH_NOTIFY_SEND_POSSIBLE` and
    /// awaits that notification on a port the reactor watches. Nothing polls in
    /// between.
    ///
    /// # Cancellation
    ///
    /// Dropping the future drops the notification port with it, so an abandoned
    /// send leaves no registration behind. The event is not sent.
    ///
    /// # Concurrent calls
    ///
    /// Await at most one `send` per subscriber at a time. The kernel keeps one
    /// `MACH_NOTIFY_SEND_POSSIBLE` request per destination; a second call while
    /// one is already waiting displaces the first, which then waits for a
    /// notification that will not come.
    ///
    /// # Errors
    ///
    /// [`Error::PeerGone`] means the subscriber's process is gone and the
    /// channel should be dropped. There is no [`Error::WouldBlock`] — that case
    /// is the wait.
    pub async fn send<E: Serialize + ?Sized>(&self, value: &E) -> Result<()> {
        let payload = self.codec.encode(value)?;
        loop {
            match msg::Outgoing::new(&self.right, &payload)
                .without_waiting()
                .send()
            {
                Err(Error::WouldBlock) => {}
                other => return other,
            }

            // Full. Ask to be told when it is not, and await that -- the
            // notification is a message on a port of our own, which is
            // something the reactor can already wait for.
            let sendable = notify::Sendable::request(self.right.as_raw())?;
            notify::Ready::new(&sendable).await;
            sendable.consume();
        }
    }

    /// Pushes one event, parking the calling thread until the subscriber has
    /// room for it.
    ///
    /// For a caller with no executor to yield to -- a thread whose whole
    /// purpose is to wait. Where there *is* one, [`Self::send`] does the same
    /// waiting without holding a thread down for it.
    ///
    /// A Mach port has no writable event (`EVFILT_MACHPORT` reports arrivals
    /// only), so waiting in the kernel is how a sender learns that space
    /// appeared without polling for it: the thread is woken at the moment the
    /// subscriber takes a message, and costs nothing until then.
    ///
    /// Never call this from a thread that something else is waiting on.
    ///
    /// # Errors
    ///
    /// [`Error::PeerGone`] means the subscriber's process is gone and the
    /// channel should be dropped. There is no [`Error::WouldBlock`] here --
    /// that case is the wait.
    pub fn send_blocking<E: Serialize + ?Sized>(&self, value: &E) -> Result<()> {
        let payload = self.codec.encode(value)?;
        msg::Outgoing::new(&self.right, &payload).send()
    }
}

/// The sending end of a service, in some other process.
///
/// Cheap to hold and reusable across any number of values, so a long-lived
/// client looks the name up once.
pub struct Sender<T, C> {
    service: SendRight,
    codec: C,
    _value: PhantomData<fn(T)>,
}

/// Written by hand rather than derived so that neither the message type nor the
/// codec has to be [`Debug`](fmt::Debug) for a port to be printable.
impl<T, C> fmt::Debug for Sender<T, C> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Sender")
            .field("service", &self.service)
            .finish_non_exhaustive()
    }
}

/// The accessors the port traits are built on. Private, which is what seals
/// [`SendPort`] and [`RecvPort`]: only this crate can name these, so only this
/// crate can add implementations.
mod sealed {
    use crate::reactor::Interest;
    use crate::rights::{RecvRight, SendRight};

    pub trait Outbound {
        fn send_right(&self) -> &SendRight;
    }

    pub trait Inbound {
        fn recv_right(&self) -> &RecvRight;
        fn interest(&self) -> &Interest;
    }
}

/// One end of a channel that can be sent on. Everything below is a provided
/// method: an implementor says which send right it holds and what it carries,
/// and the operations follow — so the async and blocking spellings of the same
/// request cannot drift apart.
pub trait SendPort: sealed::Outbound {
    /// What this end carries.
    type Message: Serialize;

    /// The format it is encoded in — every value crossing this end, including
    /// the answers to [`Self::call`] and the events a [`Self::subscribe`]
    /// yields, so a channel cannot be half in one format and half in another.
    type Codec: Codec;

    /// The codec this end was created with.
    fn codec(&self) -> &Self::Codec;

    /// Sends a value and does not wait for an answer.
    ///
    /// # Errors
    ///
    /// Returns [`Error::PeerGone`] if the receiver is gone.
    fn send(&self, value: &Self::Message) -> impl Future<Output = Result<()>> {
        async move {
            let payload = self.codec().encode(value)?;
            send_async(self.send_right(), &payload, None).await
        }
    }

    /// Sends a value and waits for the answer. A fresh reply port is allocated
    /// per call, rather than one reused for the life of the sender, so
    /// concurrent calls cannot collect each other's answers. There is
    /// deliberately no timeout; a caller that does not want to wait can drop
    /// the future.
    ///
    /// # Errors
    ///
    /// Returns [`Error::PeerGone`] if the receiver exits before answering, and
    /// [`Error::Decode`] if the answer is not an `R`.
    fn call<R: DeserializeOwned>(&self, value: &Self::Message) -> impl Future<Output = Result<R>> {
        async move {
            let port = self.request(value, Carried::AsReply)?;
            let interest = Interest::new(&port);
            let incoming =
                futures_lite::future::poll_fn(|cx| poll_recv(&port, &interest, cx)).await?;
            self.codec().decode(&incoming.payload)
        }
    }

    /// Sends a value that asks for a lasting event channel, and returns the
    /// receiving end of it. The receive right stays here; the service only
    /// gets a send right to it, so dropping the returned [`Receiver`] is what
    /// tells the service we are gone.
    ///
    /// # Errors
    ///
    /// Returns [`Error::PeerGone`] if the receiver is gone.
    fn subscribe<E: DeserializeOwned>(
        &self,
        value: &Self::Message,
    ) -> impl Future<Output = Result<Receiver<E, Self::Codec>>> {
        async move {
            let payload = self.codec().encode(value)?;
            let port = RecvRight::alloc()?;
            send_async(self.send_right(), &payload, Some(&port)).await?;
            // After the send, never before: the peer's send right is what the
            // notification is armed against.
            notify::watch_no_senders(&port)?;
            Ok(Receiver::from_port(port, self.codec().clone()))
        }
    }

    /// [`Self::send`] without an executor.
    ///
    /// # Errors
    ///
    /// Returns [`Error::PeerGone`] if the receiver is gone.
    fn send_blocking(&self, value: &Self::Message) -> Result<()> {
        msg::Outgoing::new(self.send_right(), &self.codec().encode(value)?).send()
    }

    /// [`Self::call`] without an executor.
    ///
    /// # Errors
    ///
    /// Returns [`Error::PeerGone`] if the receiver exits before answering, and
    /// [`Error::Decode`] if the answer is not an `R`.
    fn call_blocking<R: DeserializeOwned>(&self, value: &Self::Message) -> Result<R> {
        let port = self.request(value, Carried::AsReply)?;
        self.codec().decode(&msg::recv(&port)?.payload)
    }

    /// [`Self::subscribe`] without an executor.
    ///
    /// # Errors
    ///
    /// Returns [`Error::PeerGone`] if the receiver is gone.
    fn subscribe_blocking<E: DeserializeOwned>(
        &self,
        value: &Self::Message,
    ) -> Result<Receiver<E, Self::Codec>> {
        let port = self.request(value, Carried::AsChannel)?;
        // As in `subscribe`: armed after the send, so the count it arms
        // against already includes the right the peer was given.
        notify::watch_no_senders(&port)?;
        Ok(Receiver::from_port(port, self.codec().clone()))
    }

    /// Everything a request does except wait for the answer: encode, allocate
    /// somewhere for the peer to answer on, and hand the message over. The
    /// returned right is the only thing the two spellings of `call` disagree
    /// about — one polls it, the other blocks on it.
    #[doc(hidden)]
    fn request(&self, value: &Self::Message, carried: Carried) -> Result<RecvRight> {
        let payload = self.codec().encode(value)?;
        let port = RecvRight::alloc()?;
        let message = msg::Outgoing::new(self.send_right(), &payload);
        match carried {
            Carried::AsReply => message.replying_to(&port),
            Carried::AsChannel => message.carrying(&port),
        }
        .send()?;
        Ok(port)
    }
}

/// Which way the port travelling with a request is meant to be used.
#[derive(Clone, Copy)]
#[doc(hidden)]
pub enum Carried {
    /// A one-shot answer to this request.
    AsReply,
    /// A lasting channel the peer keeps pushing to.
    AsChannel,
}

/// One end of a channel that can be received on.
///
/// The mirror of [`SendPort`]: state which receive right you hold, and both
/// spellings of `recv` follow.
pub trait RecvPort: sealed::Inbound {
    /// What this end carries.
    type Message: DeserializeOwned;

    /// The format it arrives in — and the format a [`Reply`] or [`Subscriber`]
    /// off one of these deliveries answers in.
    type Codec: Codec;

    /// The codec this end was created with.
    fn codec(&self) -> &Self::Codec;

    /// Waits for the next value.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Decode`] for a value that does not match the message
    /// type. The service port is reachable by any process in the session, so
    /// that is an expected input, not a fatal condition — log it and call
    /// `recv` again.
    fn recv(&self) -> impl Future<Output = Result<Delivery<Self::Message, Self::Codec>>> {
        futures_lite::future::poll_fn(|cx| {
            poll_recv(self.recv_right(), self.interest(), cx)
                .map(|r| r.and_then(|incoming| Delivery::from_incoming(incoming, self.codec())))
        })
    }

    /// [`Self::recv`] without an executor: parks the calling thread in the
    /// kernel until a message arrives.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Decode`] on the same terms as [`Self::recv`].
    fn recv_blocking(&self) -> Result<Delivery<Self::Message, Self::Codec>> {
        Delivery::from_incoming(msg::recv(self.recv_right())?, self.codec())
    }
}

impl<T, C> sealed::Outbound for Sender<T, C> {
    fn send_right(&self) -> &SendRight {
        &self.service
    }
}

impl<T: Serialize, C: Codec> SendPort for Sender<T, C> {
    type Message = T;
    type Codec = C;

    fn codec(&self) -> &C {
        &self.codec
    }
}

impl<T, C> sealed::Inbound for Receiver<T, C> {
    fn recv_right(&self) -> &RecvRight {
        &self.port
    }

    fn interest(&self) -> &Interest {
        &self.interest
    }
}

impl<T: DeserializeOwned, C: Codec> RecvPort for Receiver<T, C> {
    type Message = T;
    type Codec = C;

    fn codec(&self) -> &C {
        &self.codec
    }
}

impl<T: Serialize, C: Codec> Sender<T, C> {
    /// Finds the service, encoding what is sent to it with `codec`.
    ///
    /// # Errors
    ///
    /// Returns [`Error::NotRunning`] when nothing has bound the name — the
    /// ordinary "the service isn't running" that clients should report as such.
    pub fn connect(service: &str, codec: C) -> Result<Self> {
        Ok(Self {
            service: bootstrap::look_up(service)?,
            codec,
            _value: PhantomData,
        })
    }
}

impl<T, C: Clone> Clone for Sender<T, C> {
    /// Cloning duplicates the port right, so every clone reaches the same
    /// service and the last one dropped releases it. The codec comes along, so
    /// a clone cannot end up speaking a different format from its original.
    fn clone(&self) -> Self {
        Self {
            service: self.service.duplicate(),
            codec: self.codec.clone(),
            _value: PhantomData,
        }
    }
}
