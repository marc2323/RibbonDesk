//! The two codecs the tests use.
//!
//! They live here rather than in the crate on purpose: the transport ships no
//! format, so a consumer writing exactly this — a unit struct and two one-line
//! methods — is the intended way to pick one, and the tests exercise the same
//! path a consumer would.

#![allow(dead_code)]

use async_mach_ports::{Codec, Error, Result};
use serde::Serialize;
use serde::de::DeserializeOwned;

/// Compact and *not* self-describing: field names never reach the wire, so
/// `deserialize_any` — and with it `#[serde(untagged)]` — is impossible.
#[derive(Clone, Copy, Debug, Default)]
pub struct Postcard;

impl Codec for Postcard {
    fn encode<T: Serialize + ?Sized>(&self, value: &T) -> Result<Vec<u8>> {
        postcard::to_allocvec(value).map_err(|_| Error::Encode)
    }

    fn decode<T: DeserializeOwned>(&self, bytes: &[u8]) -> Result<T> {
        postcard::from_bytes(bytes).map_err(|_| Error::Decode)
    }
}

/// Self-describing, via `to_vec_named`.
///
/// `rmp_serde::to_vec` would write a struct as a bare positional array, which
/// is exactly as opaque as postcard and would make this codec pointless;
/// `to_vec_named` writes a map of field name to value, which is what
/// `deserialize_any` needs to have anything to describe.
#[derive(Clone, Copy, Debug, Default)]
pub struct MessagePack;

impl Codec for MessagePack {
    fn encode<T: Serialize + ?Sized>(&self, value: &T) -> Result<Vec<u8>> {
        rmp_serde::to_vec_named(value).map_err(|_| Error::Encode)
    }

    fn decode<T: DeserializeOwned>(&self, bytes: &[u8]) -> Result<T> {
        rmp_serde::from_slice(bytes).map_err(|_| Error::Decode)
    }
}
