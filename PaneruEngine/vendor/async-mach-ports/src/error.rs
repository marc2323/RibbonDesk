//! Errors this transport can produce, and the handful of Mach codes worth
//! naming rather than passing through as numbers.

use mach2::bootstrap::{
    BOOTSTRAP_NAME_IN_USE, BOOTSTRAP_SERVICE_ACTIVE, BOOTSTRAP_UNKNOWN_SERVICE,
};
use mach2::kern_return::kern_return_t;
use mach2::message::{MACH_RCV_TIMED_OUT, MACH_SEND_INVALID_DEST, MACH_SEND_TIMED_OUT};
use serde_repr::{Deserialize_repr, Serialize_repr};
use std::fmt;

/// The result of a transport operation.
pub type Result<T> = std::result::Result<T, Error>;

/// The kernel and bootstrap statuses this transport gives a meaning to.
///
/// Carries its wire value as its representation, so a status survives a
/// round trip through serde as the number the kernel actually returned.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize_repr, Deserialize_repr)]
#[repr(i32)]
pub enum Status {
    /// The destination port is gone, which for us always means the process on
    /// the other end exited.
    SendInvalidDest = MACH_SEND_INVALID_DEST,
    /// The queue was full and we asked not to wait.
    SendTimedOut = MACH_SEND_TIMED_OUT,
    /// Nothing was queued and we asked not to wait. This is the ordinary "not
    /// ready yet" of the async receive loop, not a failure.
    RecvTimedOut = MACH_RCV_TIMED_OUT,
    /// Nobody has registered that name.
    UnknownService = BOOTSTRAP_UNKNOWN_SERVICE.cast_signed(),
    /// Somebody already has.
    NameInUse = BOOTSTRAP_NAME_IN_USE.cast_signed(),
    /// The name is registered *and* its owner is alive. This, not
    /// [`Status::NameInUse`], is what a second server actually gets.
    ServiceActive = BOOTSTRAP_SERVICE_ACTIVE.cast_signed(),
}

impl Status {
    /// The raw code, as the kernel returns it.
    #[must_use]
    pub const fn raw(self) -> kern_return_t {
        self as kern_return_t
    }

    /// `None` for a code this transport does not name; those reach the caller
    /// as [`Error::Mach`] with the raw value intact.
    #[must_use]
    pub const fn from_raw(rc: kern_return_t) -> Option<Self> {
        // The bootstrap codes are `u32` upstream, so they come back through the
        // discriminants rather than being re-cast into each pattern.
        const UNKNOWN_SERVICE: kern_return_t = Status::UnknownService.raw();
        const NAME_IN_USE: kern_return_t = Status::NameInUse.raw();
        const SERVICE_ACTIVE: kern_return_t = Status::ServiceActive.raw();

        match rc {
            MACH_SEND_INVALID_DEST => Some(Self::SendInvalidDest),
            MACH_SEND_TIMED_OUT => Some(Self::SendTimedOut),
            MACH_RCV_TIMED_OUT => Some(Self::RecvTimedOut),
            UNKNOWN_SERVICE => Some(Self::UnknownService),
            NAME_IN_USE => Some(Self::NameInUse),
            SERVICE_ACTIVE => Some(Self::ServiceActive),
            _ => None,
        }
    }
}

/// Everything that can go wrong on a Mach port channel.
///
/// The variants divide into three kinds, and a caller usually cares which:
/// the other end is not there ([`Error::NotRunning`], [`Error::PeerGone`]),
/// nothing has happened yet and this call declined to wait
/// ([`Error::WouldBlock`]), or the message itself could not be made sense of
/// ([`Error::Encode`], [`Error::Decode`]). Anything else is the kernel or the
/// bootstrap server refusing, and carries the status it refused with.
#[derive(Debug)]
pub enum Error {
    /// No process is registered under the service name. This is the ordinary
    /// "the other end isn't running" case, and clients should say so.
    NotRunning,
    /// Another process already owns the service name — a second server.
    AlreadyRunning,
    /// The peer is gone. On a reply this means the client stopped waiting; on a
    /// subscriber push it means the subscriber died and should be reaped.
    PeerGone,
    /// Nothing to do yet, and we declined to wait: on a send the peer's queue
    /// is full, on a receive the port is empty. The ordinary "not now" of a
    /// caller that asked without waiting, not a failure.
    WouldBlock,
    /// A message arrived that this protocol cannot make sense of.
    Malformed(&'static str),
    /// The service name contained an interior NUL and cannot cross into C.
    InvalidName,
    /// A descriptor-level failure from the kqueue backing an async wait.
    Io(std::io::Error),
    /// A value could not be encoded for the wire.
    Encode,
    /// A message arrived that does not decode as the expected type. Any process
    /// in the session can reach a service port, so this is an expected input
    /// rather than a bug.
    Decode,
    /// Anything else the kernel said, kept as its raw code. Every status
    /// [`Status`] names already arrives as one of the variants above, so this
    /// only ever carries a code that has no meaning here to give it.
    Mach(kern_return_t),
}

impl Error {
    /// Maps a raw kernel status onto the named cases, so callers match on
    /// meaning instead of remembering hex constants.
    pub(crate) fn from_kern(rc: kern_return_t) -> Self {
        match Status::from_raw(rc) {
            Some(Status::SendInvalidDest) => Self::PeerGone,
            Some(Status::SendTimedOut | Status::RecvTimedOut) => Self::WouldBlock,
            Some(Status::UnknownService) => Self::NotRunning,
            Some(Status::NameInUse | Status::ServiceActive) => Self::AlreadyRunning,
            None => Self::Mach(rc),
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotRunning => write!(f, "no process is registered under that service name"),
            Self::AlreadyRunning => write!(f, "another process already owns that service name"),
            Self::PeerGone => write!(f, "the peer has exited"),
            Self::WouldBlock => write!(f, "nothing is ready and waiting was declined"),
            Self::Malformed(what) => write!(f, "malformed message: {what}"),
            Self::InvalidName => write!(f, "the service name contains an interior NUL"),
            Self::Io(err) => write!(f, "{err}"),
            Self::Encode => write!(f, "the value could not be encoded"),
            Self::Decode => write!(f, "the message did not decode as the expected type"),
            Self::Mach(rc) => write!(f, "mach error {rc:#010x}"),
        }
    }
}

impl std::error::Error for Error {}
