# async-mach-ports

[![Crates.io][crate-badge]][crate]
[![docs.rs][docs-badge]][docs]

Typed channels between unrelated processes on macOS, over Mach ports.

One process binds a well-known service name with the bootstrap server and holds a
`Receiver<T, C>`; any number of unrelated processes connect a `Sender<T, C>` to that
name and send it values. Values are encoded by a `Codec` handed to the port when it
is created, which is why `T` is bounded by serde's traits. The crate ships no format
and depends on none — which bytes go on the wire is the protocol's decision, not the
transport's.

```toml
[dependencies]
async-mach-ports = "0.1"
```

## The shape of it

`std`'s channels, across process boundaries:

```rust,ignore
use async_mach_ports::{Codec, Error, Receiver, RecvPort, Result, Sender, SendPort};
use serde::{Serialize, de::DeserializeOwned};

/// The format, in full. Pick one that suits the protocol: a self-describing
/// one if it wants `#[serde(untagged)]` or `#[serde(flatten)]`, a compact
/// positional one if the schema is fixed and the bytes matter.
#[derive(Clone, Copy)]
struct MessagePack;

impl Codec for MessagePack {
    fn encode<T: Serialize + ?Sized>(&self, value: &T) -> Result<Vec<u8>> {
        rmp_serde::to_vec_named(value).map_err(|_| Error::Encode)
    }

    fn decode<T: DeserializeOwned>(&self, bytes: &[u8]) -> Result<T> {
        rmp_serde::from_slice(bytes).map_err(|_| Error::Decode)
    }
}

fn main() -> Result<()> {
    futures_lite::future::block_on(async {
        // The daemon.
        let receiver = Receiver::<Request, _>::bind("com.example.service", MessagePack)?;
        let delivery = receiver.recv().await?;
        if let Some(reply) = delivery.reply {
            reply.send(&Response)?;
        }

        // A client, in some other process, naming the same format.
        let sender = Sender::<Request, _>::connect("com.example.service", MessagePack)?;
        let response: Response = sender.call(&Request).await?;

        // The same client with no executor to run on: same names, `_blocking`.
        let response: Response = sender.call_blocking(&Request)?;
        Ok(())
    })
}
```

Every operation comes in an async/blocking pair — `send`/`send_blocking`,
`recv`/`recv_blocking`, `call`/`call_blocking` — on the `SendPort` and `RecvPort`
traits, so a client with no executor to run on is a first-class case rather than an
afterthought.

## What it adds over a plain channel

- **`Reply` — send-once request/response.** A request can carry a receive right the
  service answers on exactly once. The right is consumed by the send, so the type
  system enforces what the kernel already does.
- **`Subscriber` — lasting event streams.** A value can carry a send right that
  outlives the message that delivered it, so a service can keep pushing events to a
  process that asked for them, and reap the ones that die.
- **The wire format, chosen by the caller.** `Codec` is a serialise function and
  a deserialise function, handed to a port at `bind` or `connect` and carried by
  everything that port produces — replies, subscriber channels, event streams.
  Both ends name the same one in their types, so a mismatch is a compile error
  rather than a garbled message.
- **A kqueue reactor.** `Receiver<T, C>` is a real `Future`/`Stream`: when the port is
  empty, `poll_next` registers the task's waker against a process-wide kqueue
  watching that port with `EVFILT_MACHPORT`, rather than parking a thread inside
  `mach_msg`.
- **Or somebody else's reactor.** A process with a loop of its own — a `CFRunLoop`,
  a dispatch queue, a kqueue it already owns — can service the port instead, and
  `Receiver::as_raw_port` hands out the name to watch. A watcher that only
  *notifies* (`EVFILT_MACHPORT`, `DISPATCH_SOURCE_TYPE_MACH_RECV`) leaves the
  message queued: call `try_recv` until it answers `WouldBlock`. A watcher that
  *receives* (`CFMachPort` on a `CFRunLoop` does the `mach_msg` itself) hands the
  message over: call `decode_message` with those bytes. Either way the message
  layout, its trailer and its out-of-line memory stay inside the crate.

Port rights are typed and owned (`RecvRight`, `SendRight`, `SendOnceRight`), with
`Drop` releasing them, so the usual Mach right-leak and double-release mistakes are
not expressible.

## Platform

macOS only. The crate is built on Mach ports, the bootstrap server, and kqueue's
`EVFILT_MACHPORT`; on any other target it fails to compile with a message saying so.

## Provenance

Extracted from the `mach_ipc` crate of
[paneru](https://github.com/Karinushka/paneru), where this code was originally
written. Both are MIT-licensed.

## License

MIT. See [LICENSE](LICENSE).

[crate]: https://crates.io/crates/async-mach-ports
[crate-badge]: https://img.shields.io/crates/v/async-mach-ports.svg
[docs]: https://docs.rs/async-mach-ports
[docs-badge]: https://docs.rs/async-mach-ports/badge.svg
