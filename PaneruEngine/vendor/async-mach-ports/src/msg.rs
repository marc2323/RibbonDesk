//! Building and parsing the two message shapes this protocol uses.
//!
//! # Why `packed(4)`
//!
//! A complex Mach message header is 24 bytes, then a 4-byte body count, so the
//! first descriptor begins at offset 28. A plain `#[repr(C)]` struct would pad
//! the OOL descriptor's 64-bit `address` to offset 32, describing a message the
//! kernel does not recognise — hence `packed(4)`, matching Apple's own
//! `#pragma pack(4)`. The offsets are asserted below rather than trusted.
//!
//! Because fields of a packed struct are not necessarily aligned, they are read
//! and written through raw pointers rather than by reference: taking a `&` to a
//! misaligned field is undefined behaviour even if it is never dereferenced.

use mach2::kern_return::KERN_SUCCESS;
use mach2::message::{
    MACH_MSG_OOL_DESCRIPTOR, MACH_MSG_PORT_DESCRIPTOR, MACH_MSG_TYPE_COPY_SEND,
    MACH_MSG_TYPE_MAKE_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE, MACH_MSG_TYPE_MOVE_SEND,
    MACH_MSG_TYPE_MOVE_SEND_ONCE, MACH_MSG_VIRTUAL_COPY, MACH_MSGH_BITS_COMPLEX,
    MACH_MSGH_BITS_LOCAL_MASK, MACH_MSGH_BITS_REMOTE_MASK, MACH_RCV_MSG, MACH_RCV_TIMEOUT,
    MACH_SEND_MSG, MACH_SEND_TIMEOUT, mach_msg, mach_msg_audit_trailer_t, mach_msg_bits_t,
    mach_msg_body_t, mach_msg_descriptor_type_t, mach_msg_header_t, mach_msg_ool_descriptor_t,
    mach_msg_option_t, mach_msg_port_descriptor_t, mach_msg_size_t, mach_msg_type_name_t,
};
use mach2::notify::{MACH_NOTIFY_NO_SENDERS, MACH_NOTIFY_SEND_ONCE};
use mach2::port::{MACH_PORT_NULL, mach_port_name_t, mach_port_t};
use mach2::traps::mach_task_self;
use mach2::vm::mach_vm_deallocate;
use mach2::vm_types::{mach_port_context_t, mach_vm_address_t};

use bitflags::bitflags;

use std::ffi::c_int;
use std::mem::offset_of;

use crate::error::{Error, Result};
use crate::rights::{RecvRight, SendOnceRight, SendRight};

/// A request carrying its payload out of line, and nothing else.
#[repr(C, packed(4))]
#[derive(Clone, Copy)]
struct OolMsg {
    header: mach_msg_header_t,
    body: mach_msg_body_t,
    payload: mach_msg_ool_descriptor_t,
}

/// The same, plus one port the sender is handing over — a subscriber's send
/// right.
#[repr(C, packed(4))]
#[derive(Clone, Copy)]
struct OolPortMsg {
    header: mach_msg_header_t,
    body: mach_msg_body_t,
    payload: mach_msg_ool_descriptor_t,
    port: mach_msg_port_descriptor_t,
}

/// How many descriptors each shape carries. This is what tells the two apart on
/// receive, so it is named rather than written as a bare count.
const DESCRIPTORS_PAYLOAD_ONLY: mach_msg_size_t = 1;
const DESCRIPTORS_WITH_PORT: mach_msg_size_t = 2;

/// The kernel's layout, not the compiler's preference — checked at compile
/// time since a mismatch here means the transport silently talks nonsense.
/// Every offset is derived, so the assertions say "nothing is padded" rather
/// than restating a number that would have to be kept in step by hand.
const _: () = {
    const HEADER: usize = size_of::<mach_msg_header_t>();
    const BODY: usize = size_of::<mach_msg_body_t>();
    const OOL: usize = size_of::<mach_msg_ool_descriptor_t>();

    assert!(offset_of!(OolMsg, body) == HEADER);
    assert!(offset_of!(OolMsg, payload) == HEADER + BODY);
    assert!(offset_of!(OolPortMsg, body) == HEADER);
    assert!(offset_of!(OolPortMsg, payload) == HEADER + BODY);
    assert!(offset_of!(OolPortMsg, port) == HEADER + BODY + OOL);
    // `OolMsg` is exactly the leading part of `OolPortMsg`, which is what lets
    // `parse` read the shorter shape first to learn which one it is holding.
    assert!(size_of::<OolMsg>() == offset_of!(OolPortMsg, port));
};

/// What the kernel does with the port right named beside this disposition.
///
/// The same values name what a *received* right carries: Apple's headers define
/// `MACH_MSG_TYPE_PORT_SEND` and `..._SEND_ONCE` as aliases for the `MOVE`
/// variants, and mach2 does not re-export the aliases.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
enum Disposition {
    /// A send right we hand over; also what a received send right reads as.
    MoveSend = MACH_MSG_TYPE_MOVE_SEND,
    /// A send-once right the send consumes; also what a received one reads as.
    MoveSendOnce = MACH_MSG_TYPE_MOVE_SEND_ONCE,
    /// Keep our send right; the kernel takes a reference of its own.
    CopySend = MACH_MSG_TYPE_COPY_SEND,
    /// Make a send right from a receive right we keep.
    MakeSend = MACH_MSG_TYPE_MAKE_SEND,
    /// Make a send-once right from a receive right we keep.
    MakeSendOnce = MACH_MSG_TYPE_MAKE_SEND_ONCE,
}

impl Disposition {
    const fn raw(self) -> mach_msg_type_name_t {
        self as mach_msg_type_name_t
    }

    /// `None` for anything this protocol does not name, so an unexpected
    /// disposition falls through to the caller's rejection path.
    const fn from_raw(raw: mach_msg_type_name_t) -> Option<Self> {
        match raw {
            MACH_MSG_TYPE_MOVE_SEND => Some(Self::MoveSend),
            MACH_MSG_TYPE_MOVE_SEND_ONCE => Some(Self::MoveSendOnce),
            MACH_MSG_TYPE_COPY_SEND => Some(Self::CopySend),
            MACH_MSG_TYPE_MAKE_SEND => Some(Self::MakeSend),
            MACH_MSG_TYPE_MAKE_SEND_ONCE => Some(Self::MakeSendOnce),
            _ => None,
        }
    }
}

bitflags! {
    /// The genuine flag bits of `msgh_bits`, as opposed to the two disposition
    /// fields packed into the same word.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    struct MsgFlags: mach_msg_bits_t {
        const COMPLEX = MACH_MSGH_BITS_COMPLEX;
    }
}

/// A header's `msgh_bits`: two [`Disposition`] fields packed beside
/// [`MsgFlags`], the remote one in the low bits and the local one a byte above.
///
/// Composing the two halves is confined to [`MsgBits::complex`] so no shifting
/// or masking escapes into the rest of the module.
#[derive(Clone, Copy)]
struct MsgBits(mach_msg_bits_t);

impl MsgBits {
    /// The distance from the remote field to the local one, which is what
    /// `MACH_MSGH_BITS_LOCAL_MASK` is `MACH_MSGH_BITS_REMOTE_MASK` shifted by.
    const LOCAL_SHIFT: u32 = MACH_MSGH_BITS_LOCAL_MASK.trailing_zeros();

    /// Every message this protocol sends carries its payload out of line, so
    /// there is no non-complex constructor.
    fn complex(remote: Disposition, local: Option<Disposition>) -> Self {
        let local = local.map_or(0, |d| d.raw() << Self::LOCAL_SHIFT);
        Self(remote.raw() | local | MsgFlags::COMPLEX.bits())
    }

    const fn raw(self) -> mach_msg_bits_t {
        self.0
    }

    /// Unknown bits are dropped rather than rejected: the kernel sets flags
    /// this protocol has no opinion about.
    fn flags(self) -> MsgFlags {
        MsgFlags::from_bits_truncate(self.0)
    }

    /// The disposition in the remote field. On receive the two fields swap: the
    /// sender's local reply port arrives here, because the reply destination is
    /// now the far end from our side.
    const fn remote(self) -> Option<Disposition> {
        Disposition::from_raw(self.0 & MACH_MSGH_BITS_REMOTE_MASK)
    }
}

/// The local field must sit exactly one byte above the remote one for the shift
/// above to land inside its mask.
const _: () =
    assert!(MACH_MSGH_BITS_REMOTE_MASK << MsgBits::LOCAL_SHIFT == MACH_MSGH_BITS_LOCAL_MASK);

/// The descriptor kinds this protocol understands, as the kernel writes them
/// into each descriptor's `type_`. Anything else is [`Error::Malformed`]
/// rather than a variant.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
enum DescriptorKind {
    Port = MACH_MSG_PORT_DESCRIPTOR,
    Ool = MACH_MSG_OOL_DESCRIPTOR,
}

impl TryFrom<u8> for DescriptorKind {
    type Error = Error;

    fn try_from(byte: u8) -> Result<Self> {
        match mach_msg_descriptor_type_t::from(byte) {
            MACH_MSG_PORT_DESCRIPTOR => Ok(Self::Port),
            MACH_MSG_OOL_DESCRIPTOR => Ok(Self::Ool),
            _ => Err(Error::Malformed("unsupported descriptor kind")),
        }
    }
}
/// Apple's `mach_msg_max_trailer_t`, which mach2 does not define: an audit
/// trailer followed by a context, an `int` and a label set. We ask for no
/// trailer, but the buffer must still fit the largest the kernel may write.
const MAX_TRAILER_BYTES: usize = size_of::<mach_msg_audit_trailer_t>()
    + size_of::<mach_port_context_t>()
    + size_of::<c_int>()
    + size_of::<mach_port_name_t>();

/// Both descriptors and that trailer, rounded up for slack. Our protocol never
/// sends inline data, so nothing legitimate is bigger than this and anything
/// that is gets rejected rather than allocated for.
const RECV_BUFFER_BYTES: usize = (size_of::<OolPortMsg>() + MAX_TRAILER_BYTES).next_multiple_of(64);

bitflags! {
    /// The `options` word `mach_msg` takes, which selects the direction and
    /// whether an empty or full queue waits or returns.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    struct MsgOptions: mach_msg_option_t {
        const SEND = MACH_SEND_MSG;
        const RECV = MACH_RCV_MSG;
        /// Without this a full queue waits for room.
        const SEND_TIMEOUT = MACH_SEND_TIMEOUT;
        /// Without this an empty queue parks the thread in the kernel.
        const RECV_TIMEOUT = MACH_RCV_TIMEOUT;
    }
}

/// How the destination port right should be treated when sending.
#[derive(Clone, Copy)]
pub(crate) enum Dest {
    /// Keep our send right; the kernel takes a reference of its own. Used for
    /// the service port, which a client talks to repeatedly.
    CopySend,
    /// Hand over a send-once right, which the send consumes. Used for replies.
    MoveSendOnce,
}

/// An 8-byte aligned receive buffer.
///
/// Alignment matters: the header is read through a `*const mach_msg_header_t`,
/// and while the descriptors within are deliberately under-aligned, the buffer
/// they sit in must not be.
#[repr(C, align(8))]
struct RecvBuffer([u8; RECV_BUFFER_BYTES]);

/// One message off the wire, with its payload copied out and its rights owned.
pub struct Incoming {
    /// The request bytes, already copied out of the kernel's mapping.
    pub payload: Vec<u8>,
    /// Where the answer goes, if the sender asked for one.
    pub reply: Option<SendOnceRight>,
    /// Send rights the peer handed over — a subscriber registering itself.
    pub ports: Vec<SendRight>,
}

/// One outgoing message.
pub(crate) struct Outgoing<'a> {
    /// The port to send to. Raw only at this boundary: the constructors take
    /// the owned right, so a caller never hands over a name whose right has
    /// already been released.
    dest: mach_port_t,
    /// What the destination right is, and so what the kernel does with it.
    dest_kind: Dest,
    payload: &'a [u8],
    /// A receive right to answer on, turning this into a request.
    reply_port: Option<mach_port_t>,
    /// A further right to hand over, which is how a subscription is set up.
    extra_port: Option<mach_port_t>,
    /// `Some(0)` fails rather than waits when the peer's queue is full — what
    /// broadcasting needs, so a stalled subscriber cannot stall the daemon.
    /// `None` waits for room.
    timeout: Option<u32>,
}

impl Outgoing<'_> {
    /// The ordinary request/command: just a payload for the service.
    pub(crate) fn new<'a>(service: &SendRight, payload: &'a [u8]) -> Outgoing<'a> {
        Outgoing {
            dest: service.as_raw(),
            dest_kind: Dest::CopySend,
            payload,
            reply_port: None,
            extra_port: None,
            timeout: None,
        }
    }

    /// Asks for an answer on `port`, a right we own and keep.
    #[must_use]
    pub(crate) fn replying_to(mut self, port: &RecvRight) -> Self {
        self.reply_port = Some(port.as_raw());
        self
    }

    /// Carries a further right across, handing the peer a channel back.
    #[must_use]
    pub(crate) fn carrying(mut self, port: &RecvRight) -> Self {
        self.extra_port = Some(port.as_raw());
        self
    }

    /// Fails rather than waits when the peer's queue is full.
    #[must_use]
    pub(crate) fn without_waiting(mut self) -> Self {
        self.timeout = Some(0);
        self
    }

    /// An answer travelling back down a send-once right, which the send
    /// consumes — hence taking it by value rather than by reference.
    pub(crate) fn answering(right: SendOnceRight, payload: &[u8]) -> Outgoing<'_> {
        Outgoing {
            // `into_raw` because a successful send consumes the right; letting
            // `Drop` release it as well would be a double free.
            dest: right.into_raw(),
            dest_kind: Dest::MoveSendOnce,
            payload,
            reply_port: None,
            extra_port: None,
            timeout: None,
        }
    }

    /// Hands this message to the kernel, carrying its payload out of line.
    pub(crate) fn send(self) -> Result<()> {
        let Outgoing {
            dest,
            dest_kind,
            payload,
            reply_port,
            extra_port,
            timeout,
        } = self;
        let remote = match dest_kind {
            Dest::CopySend => Disposition::CopySend,
            Dest::MoveSendOnce => Disposition::MoveSendOnce,
        };
        // A reply port is a receive right we keep, so the peer gets a send-once
        // right made from it.
        let local = reply_port.map(|_| Disposition::MakeSendOnce);

        let size = if extra_port.is_some() {
            size_of::<OolPortMsg>()
        } else {
            size_of::<OolMsg>()
        };

        let header = mach_msg_header_t {
            msgh_bits: MsgBits::complex(remote, local).raw(),
            msgh_size: u32::try_from(size).map_err(|_| Error::Malformed("message too large"))?,
            msgh_remote_port: dest,
            msgh_local_port: reply_port.unwrap_or(MACH_PORT_NULL),
            msgh_voucher_port: MACH_PORT_NULL,
            msgh_id: 0,
        };
        let body = mach_msg_body_t {
            msgh_descriptor_count: if extra_port.is_some() {
                DESCRIPTORS_WITH_PORT
            } else {
                DESCRIPTORS_PAYLOAD_ONLY
            },
        };
        // `deallocate: false` — the kernel copies out of our buffer and we keep it.
        // Virtual copy so it is copy-on-write rather than an eager bulk copy, which
        // is what makes a large window set cheap to send.
        let descriptor = mach_msg_ool_descriptor_t::new(
            payload.as_ptr() as *mut _,
            false,
            MACH_MSG_VIRTUAL_COPY,
            mach_msg_size_t::try_from(payload.len())
                .map_err(|_| Error::Malformed("payload too large"))?,
        );

        let mut with_port;
        let mut without_port;
        let (buffer, len): (*mut mach_msg_header_t, usize) = if let Some(port) = extra_port {
            with_port = OolPortMsg {
                header,
                body,
                payload: descriptor,
                port: mach_msg_port_descriptor_t::new(port, Disposition::MakeSend.raw()),
            };
            (std::ptr::addr_of_mut!(with_port).cast(), size)
        } else {
            without_port = OolMsg {
                header,
                body,
                payload: descriptor,
            };
            (std::ptr::addr_of_mut!(without_port).cast(), size)
        };

        let (options, timeout_ms) = match timeout {
            Some(ms) => (MsgOptions::SEND | MsgOptions::SEND_TIMEOUT, ms),
            None => (MsgOptions::SEND, 0),
        };

        // SAFETY: `buffer` points at a fully initialised message of `len` bytes
        // whose header describes it, and `payload` outlives this call.
        let rc = unsafe {
            mach_msg(
                buffer,
                options.bits(),
                u32::try_from(len).map_err(|_| Error::Malformed("message too large"))?,
                0,
                MACH_PORT_NULL,
                timeout_ms,
                MACH_PORT_NULL,
            )
        };

        if rc == KERN_SUCCESS {
            Ok(())
        } else {
            Err(Error::from_kern(rc))
        }
    }
}

/// Receives without blocking and discards whatever arrives, without trying to
/// [`parse`] it as one of this protocol's two message shapes.
///
/// For a kernel notification (`MACH_NOTIFY_SEND_POSSIBLE`, in particular) the
/// arrival *is* the answer and the message is a different, simple shape that
/// `parse` was never built to recognise -- running it through `parse` reports
/// [`Error::Malformed`] even though the receive itself succeeded, which drops
/// the one signal a waiting sender needed. This drains the same way `try_recv`
/// does but stops before the shape-specific part.
///
/// # Errors
///
/// [`Error::WouldBlock`] if nothing is waiting.
pub(crate) fn try_recv_signal(port: &RecvRight) -> Result<()> {
    let mut buffer = RecvBuffer([0u8; RECV_BUFFER_BYTES]);

    // SAFETY: as in `recv_with` -- `buffer` is 8-aligned and `RECV_BUFFER_BYTES`
    // long, matching the size argument.
    let rc = unsafe {
        mach_msg(
            std::ptr::addr_of_mut!(buffer).cast::<mach_msg_header_t>(),
            (MsgOptions::RECV | MsgOptions::RECV_TIMEOUT).bits(),
            0,
            u32::try_from(RECV_BUFFER_BYTES).expect("the buffer size fits in a u32"),
            port.as_raw(),
            0,
            MACH_PORT_NULL,
        )
    };
    if rc == KERN_SUCCESS {
        Ok(())
    } else {
        Err(Error::from_kern(rc))
    }
}

/// Receives without blocking, reporting [`Error::WouldBlock`] when the port is
/// empty.
pub(crate) fn try_recv(port: &RecvRight) -> Result<Incoming> {
    recv_with(
        port.as_raw(),
        MsgOptions::RECV | MsgOptions::RECV_TIMEOUT,
        0,
    )
}

/// Receives, parking the calling thread in the kernel until a message arrives.
/// The same call as [`try_recv`] without [`MsgOptions::RECV_TIMEOUT`], which is
/// what turns the immediate `WouldBlock` return into an indefinite wait.
pub(crate) fn recv(port: &RecvRight) -> Result<Incoming> {
    recv_with(port.as_raw(), MsgOptions::RECV, 0)
}

/// The one `mach_msg` receive, which [`try_recv`] and [`recv`] differ only in
/// the options they hand it.
fn recv_with(port: mach_port_t, options: MsgOptions, timeout: u32) -> Result<Incoming> {
    let mut buffer = RecvBuffer([0u8; RECV_BUFFER_BYTES]);

    // SAFETY: `buffer` is 8-aligned and `RECV_BUFFER_BYTES` long, which is what
    // the size argument claims.
    let rc = unsafe {
        mach_msg(
            std::ptr::addr_of_mut!(buffer).cast::<mach_msg_header_t>(),
            options.bits(),
            0,
            u32::try_from(RECV_BUFFER_BYTES).expect("the buffer size fits in a u32"),
            port,
            timeout,
            MACH_PORT_NULL,
        )
    };
    if rc != KERN_SUCCESS {
        return Err(Error::from_kern(rc));
    }

    parse(&buffer.0)
}

/// Copies one of the two message shapes out of the receive buffer.
///
/// `read_unaligned` because a descriptor sits at a 4-byte offset while its type
/// wants 8: the buffer itself is 8-aligned, but the fields inside deliberately
/// are not, and a reference to one would be undefined behaviour.
fn read_shape<T: Copy>(bytes: &[u8]) -> Result<T> {
    if bytes.len() < size_of::<T>() {
        return Err(Error::Malformed("message is shorter than its shape"));
    }
    // SAFETY: the length is checked above, `bytes` is fully initialised, and
    // `T` is one of the `repr(C, packed(4))` shapes asserted to match the
    // kernel's layout.
    Ok(unsafe { std::ptr::read_unaligned(bytes.as_ptr().cast::<T>()) })
}

/// Copies the payload out of the kernel's mapping and releases it.
fn take_payload(descriptor: mach_msg_ool_descriptor_t) -> Result<Vec<u8>> {
    if DescriptorKind::try_from(descriptor.type_)? != DescriptorKind::Ool {
        return Err(Error::Malformed(
            "the payload descriptor is not out of line",
        ));
    }

    let address = descriptor.address;
    let size = descriptor.size;
    if address.is_null() || size == 0 {
        return Ok(Vec::new());
    }

    // SAFETY: the kernel mapped `size` readable bytes at `address` into this
    // task for exactly this purpose.
    let payload = if size as usize > crate::MAX_PAYLOAD_BYTES {
        Err(Error::Malformed("payload exceeds the transport limit"))
    } else {
        // SAFETY: the kernel mapped this checked-size region into our task.
        Ok(unsafe { std::slice::from_raw_parts(address.cast::<u8>(), size as usize) }.to_vec())
    };

    // The mapping is ours now and nothing else will release it.
    // SAFETY: `address`/`size` name the region just received.
    unsafe {
        mach_vm_deallocate(
            mach_task_self(),
            address as mach_vm_address_t,
            u64::from(size),
        );
    }
    payload
}

/// The send right a peer handed over, if the descriptor really carries one.
fn take_port(descriptor: mach_msg_port_descriptor_t) -> Result<Option<SendRight>> {
    if DescriptorKind::try_from(descriptor.type_)? != DescriptorKind::Port {
        return Err(Error::Malformed("the carried descriptor is not a port"));
    }

    let carried = Disposition::from_raw(mach_msg_type_name_t::from(descriptor.disposition));
    if carried != Some(Disposition::MoveSend) || descriptor.name == MACH_PORT_NULL {
        return Ok(None);
    }
    // SAFETY: the kernel just transferred this send right to us.
    Ok(Some(unsafe { SendRight::from_raw(descriptor.name) }))
}

/// Pulls the payload and any rights out of a received message.
///
/// A message this protocol does not understand is reported as
/// [`Error::Malformed`] rather than panicking: the service port is reachable by
/// any process in the session, so a bad frame is an expected input, not a bug.
pub(crate) fn parse(bytes: &[u8]) -> Result<Incoming> {
    // The header alone, before the shape: a message that is not one of ours is
    // shorter than either shape, and a slice sized to it -- which is what a
    // reactor that received the message hands over -- must be recognised
    // rather than rejected for being too short.
    let header = read_shape::<mach_msg_header_t>(bytes)?;
    let bits = MsgBits(header.msgh_bits);

    let reply = match bits.remote() {
        Some(Disposition::MoveSendOnce) if header.msgh_remote_port != MACH_PORT_NULL => {
            // SAFETY: the kernel just gave this task the right.
            Some(unsafe { SendOnceRight::from_raw(header.msgh_remote_port) })
        }
        _ => None,
    };

    // What the kernel sends a client still waiting on its reply port when the
    // process holding the send-once right to it dies without answering -- a
    // daemon that exited mid-request. It is a simple message, so without this
    // it is reported as a malformed one rather than as the peer being gone.
    if header.msgh_id == MACH_NOTIFY_SEND_ONCE {
        return Err(Error::PeerGone);
    }

    // The same fact about a subscription channel rather than a reply port: the
    // peer held a plain send right, it died, and the kernel says so here
    // because `notify::watch_no_senders` asked it to. Also simple, so it needs
    // the same exemption from the complex-message check below.
    if header.msgh_id == MACH_NOTIFY_NO_SENDERS {
        return Err(Error::PeerGone);
    }

    if !bits.flags().contains(MsgFlags::COMPLEX) {
        return Err(Error::Malformed("not a complex message"));
    }

    // Both shapes start with this one, so it can be read before the descriptor
    // count says which of them actually arrived.
    let message = read_shape::<OolMsg>(bytes)?;
    // Even a rejected payload must consume/drop an attached subscriber right.
    let payload = take_payload(message.payload);

    let body = message.body;
    let ports = match body.msgh_descriptor_count {
        DESCRIPTORS_PAYLOAD_ONLY => Vec::new(),
        DESCRIPTORS_WITH_PORT => {
            let message = read_shape::<OolPortMsg>(bytes)?;
            take_port(message.port)?.into_iter().collect()
        }
        _ => return Err(Error::Malformed("unexpected descriptor count")),
    };

    Ok(Incoming {
        payload: payload?,
        reply,
        ports,
    })
}

/// Sends `payload` on a send-once right, consuming it.
pub(crate) fn reply(right: SendOnceRight, payload: &[u8]) -> Result<()> {
    Outgoing::answering(right, payload).without_waiting().send()
}

#[cfg(test)]
mod tests {
    use super::*;

    use mach2::message::mach_msg_id_t;

    /// A frame written out field by field in the kernel's order, rather than by
    /// copying one of the shapes above into bytes. Building the input from the
    /// structs under test would only check them against themselves, and the
    /// offsets are the whole risk here.
    ///
    /// These are also the only tests of this module miri can run: everything
    /// else reaches `mach_msg`, and a frame built by hand reaches the pointer
    /// arithmetic in [`read_shape`] and [`parse`] without it.
    fn header_bytes(bits: mach_msg_bits_t, remote: mach_port_t, id: mach_msg_id_t) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&bits.to_ne_bytes());
        out.extend_from_slice(&0u32.to_ne_bytes()); // msgh_size, which parsing ignores
        out.extend_from_slice(&remote.to_ne_bytes());
        out.extend_from_slice(&MACH_PORT_NULL.to_ne_bytes()); // local
        out.extend_from_slice(&MACH_PORT_NULL.to_ne_bytes()); // voucher
        out.extend_from_slice(&id.to_ne_bytes());
        out
    }

    /// An out-of-line descriptor naming no memory. That is what lets these
    /// tests run at all: a null address of zero bytes is copied as an empty
    /// payload and never handed to `mach_vm_deallocate`.
    fn empty_ool() -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&0u64.to_ne_bytes()); // address
        out.extend_from_slice(&[0, 0, 0]); // deallocate, copy, pad1
        out.push(u8::try_from(MACH_MSG_OOL_DESCRIPTOR).expect("a descriptor kind is a byte"));
        out.extend_from_slice(&0u32.to_ne_bytes()); // size
        out
    }

    /// A port descriptor recognised as one, carrying no right to own — so no
    /// [`SendRight`] is built and nothing is released on drop.
    fn null_port() -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&MACH_PORT_NULL.to_ne_bytes()); // name
        out.extend_from_slice(&0u32.to_ne_bytes()); // pad1
        out.extend_from_slice(&0u16.to_ne_bytes()); // pad2
        out.push(u8::try_from(MACH_MSG_TYPE_MOVE_SEND).expect("a disposition is a byte"));
        out.push(u8::try_from(MACH_MSG_PORT_DESCRIPTOR).expect("a descriptor kind is a byte"));
        out
    }

    /// A complex message of `descriptors` descriptors, always long enough for
    /// the longer shape so that a wrong count is refused for being wrong
    /// rather than for being short.
    fn complex_bytes(descriptors: mach_msg_size_t) -> Vec<u8> {
        let mut out = header_bytes(MACH_MSGH_BITS_COMPLEX, MACH_PORT_NULL, 0);
        out.extend_from_slice(&descriptors.to_ne_bytes());
        out.extend(empty_ool());
        out.extend(null_port());
        out
    }

    #[test]
    fn a_buffer_shorter_than_the_shape_is_refused_rather_than_read() {
        let nearly = vec![0u8; size_of::<mach_msg_header_t>() - 1];
        assert!(matches!(
            read_shape::<mach_msg_header_t>(&nearly),
            Err(Error::Malformed(_))
        ));
        let header_only = header_bytes(MACH_MSGH_BITS_COMPLEX, MACH_PORT_NULL, 0);
        assert!(matches!(
            read_shape::<OolMsg>(&header_only),
            Err(Error::Malformed(_))
        ));
    }

    #[test]
    fn a_shape_is_read_out_of_a_buffer_nothing_is_aligned_for() {
        // One byte of lead-in puts every field inside off its own alignment,
        // which is the case `read_unaligned` is there for.
        let mut bytes = vec![0xAA_u8];
        bytes.extend(complex_bytes(DESCRIPTORS_WITH_PORT));

        let message = read_shape::<OolPortMsg>(&bytes[1..]).expect("the shape fits");
        let count = message.body.msgh_descriptor_count;
        assert_eq!(count, DESCRIPTORS_WITH_PORT);
        let payload = message.payload;
        assert_eq!(payload.size, 0);
        assert!(payload.address.is_null());
        let port = message.port;
        assert_eq!(port.name, MACH_PORT_NULL);
    }

    #[test]
    fn a_simple_message_is_not_one_of_ours() {
        let simple = header_bytes(0, MACH_PORT_NULL, 0);
        assert!(matches!(parse(&simple), Err(Error::Malformed(_))));
    }

    #[test]
    fn the_kernels_send_once_notification_reads_as_the_peer_being_gone() {
        let notice = header_bytes(0, MACH_PORT_NULL, MACH_NOTIFY_SEND_ONCE);
        assert!(matches!(parse(&notice), Err(Error::PeerGone)));
    }

    #[test]
    fn a_payload_only_message_parses_with_nothing_owned() {
        let incoming = parse(&complex_bytes(DESCRIPTORS_PAYLOAD_ONLY)).expect("a valid frame");
        assert!(incoming.payload.is_empty());
        assert!(incoming.reply.is_none());
        assert!(incoming.ports.is_empty());
    }

    #[test]
    fn a_port_carrying_message_is_read_as_the_longer_shape() {
        let incoming = parse(&complex_bytes(DESCRIPTORS_WITH_PORT)).expect("a valid frame");
        assert!(incoming.payload.is_empty());
        // The descriptor is a port descriptor naming no port, so there is
        // nothing to hand on -- reading it at all is the point.
        assert!(incoming.ports.is_empty());
    }

    #[test]
    fn a_descriptor_count_this_protocol_does_not_use_is_refused() {
        let mut odd = complex_bytes(DESCRIPTORS_WITH_PORT);
        let at = offset_of!(OolMsg, body);
        odd[at..at + size_of::<mach_msg_size_t>()].copy_from_slice(&3_u32.to_ne_bytes());
        assert!(matches!(parse(&odd), Err(Error::Malformed(_))));
    }

    #[test]
    fn a_descriptor_kind_this_protocol_does_not_use_is_refused() {
        let mut wrong = complex_bytes(DESCRIPTORS_PAYLOAD_ONLY);
        let at = offset_of!(OolMsg, payload) + offset_of!(mach_msg_ool_descriptor_t, type_);
        wrong[at] = u8::MAX;
        assert!(matches!(parse(&wrong), Err(Error::Malformed(_))));
    }

    #[test]
    fn the_dispositions_and_the_complex_flag_share_one_word_without_colliding() {
        let bits = MsgBits::complex(Disposition::CopySend, Some(Disposition::MakeSendOnce));
        assert_eq!(bits.remote(), Some(Disposition::CopySend));
        assert!(bits.flags().contains(MsgFlags::COMPLEX));

        let local = MsgBits(bits.raw() >> MsgBits::LOCAL_SHIFT);
        assert_eq!(local.remote(), Some(Disposition::MakeSendOnce));
    }
}
