//! The wire format, given to a port when it is created.
//!
//! A transport has to turn values into bytes, but it has no business deciding
//! *which* bytes. The two ends of a channel only have to agree with each other,
//! and what they should agree on depends on the protocol they carry: a compact
//! non-self-describing format is the right answer for a fixed schema and the
//! wrong one for a protocol that wants serde's more declarative attributes
//! (`#[serde(untagged)]`, `#[serde(flatten)]`), which need `deserialize_any`
//! and so need the format to describe itself.
//!
//! So this crate has no format of its own, no dependency on one, and no feature
//! flags selecting between formats it happens to know about. [`Codec`] pairs a
//! serialise function with a deserialise function; a caller hands one to
//! [`bind`](crate::Receiver::bind) or [`connect`](crate::Sender::connect) and
//! the port uses it for everything that crosses it. Because the codec is part
//! of the port's type, two ends that disagree about the format fail to compile
//! rather than failing at run time.

use crate::Result;
use serde::Serialize;
use serde::de::DeserializeOwned;

/// The serialise and deserialise functions a port encodes with.
///
/// The two methods have to be generic — a port encodes its message type, its
/// replies and its pushed events, which are three different types — so this is
/// a trait rather than a pair of `fn` fields, and a codec is a value of a type
/// implementing it. There is normally no state to carry, so that value is a
/// unit struct and every serde format crate already supplies the two bodies:
///
/// ```
/// # use serde::{Serialize, de::DeserializeOwned};
/// use async_mach_ports::{Codec, Error, Result};
///
/// /// MessagePack, self-describing: `to_vec_named` writes struct fields as a
/// /// map of names, where `to_vec` would write a bare positional array.
/// #[derive(Clone, Copy)]
/// pub struct MessagePack;
///
/// impl Codec for MessagePack {
///     fn encode<T: Serialize + ?Sized>(&self, value: &T) -> Result<Vec<u8>> {
///         rmp_serde::to_vec_named(value).map_err(|_| Error::Encode)
///     }
///
///     fn decode<T: DeserializeOwned>(&self, bytes: &[u8]) -> Result<T> {
///         rmp_serde::from_slice(bytes).map_err(|_| Error::Decode)
///     }
/// }
/// ```
///
/// [`Clone`] is a supertrait because a received value can hand back a
/// [`Reply`](crate::Reply) and a [`Subscriber`](crate::Subscriber), and those
/// outlive the delivery that carried them: each needs its own copy of the codec
/// to answer with. A unit struct makes that free.
///
/// Both methods report this crate's [`Error::Encode`](crate::Error::Encode) and [`Error::Decode`](crate::Error::Decode)
/// rather than carrying a format-specific error type of their own. That is
/// deliberate: it is what lets every operation on a port report the same error
/// for the same fault whichever format is underneath, so a caller matching on
/// [`Error`](crate::Error) never has to know which codec was chosen. A format's own error
/// detail is worth logging at the `map_err`, not threading through this crate.
#[diagnostic::on_unimplemented(
    message = "`{Self}` is not a wire format: it has no `Codec` impl",
    note = "a codec is a `Clone` unit struct with an `encode` and a `decode`, usually one line each over a serde format crate's `to_vec`/`from_slice`"
)]
pub trait Codec: Clone {
    /// Encodes a value for the wire.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Encode`](crate::Error::Encode) if the value cannot be represented in this
    /// format — a sequence of unknown length, for instance, which some formats
    /// cannot write.
    fn encode<T: Serialize + ?Sized>(&self, value: &T) -> Result<Vec<u8>>;

    /// Decodes bytes that arrived over the wire.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Decode`](crate::Error::Decode) if the bytes are not a `T`. Any process in the
    /// session can reach a service port, so this is an expected input rather
    /// than a bug.
    fn decode<T: DeserializeOwned>(&self, bytes: &[u8]) -> Result<T>;
}
