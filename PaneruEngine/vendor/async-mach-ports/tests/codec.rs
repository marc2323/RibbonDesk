//! What making the format a parameter actually bought.
//!
//! The transport ships no codec, so these tests stand in for a consumer's:
//! [`support::Postcard`] and [`support::MessagePack`] are written here exactly
//! as a consumer would write them, and the assertions are about the difference
//! between them rather than about anything the crate does.

mod support;

use async_mach_ports::{Codec, Error, Receiver, RecvPort, SendPort, Sender};
use futures_lite::future::block_on;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use support::{MessagePack, Postcard};

/// The shape the rsbar protocol wants and postcard forbids: a value that reads
/// as either a bare string or the whole object.
#[derive(Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "LabelRepr")]
struct Label {
    text: String,
    width: Option<u32>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum LabelRepr {
    Text(String),
    Object { text: String, width: Option<u32> },
}

impl From<LabelRepr> for Label {
    fn from(value: LabelRepr) -> Self {
        match value {
            LabelRepr::Text(text) => Self { text, width: None },
            LabelRepr::Object { text, width } => Self { text, width },
        }
    }
}

/// The point of the exercise. `untagged` buffers its input and re-reads it,
/// which needs `deserialize_any`; postcard refuses that outright, so the same
/// type that cannot survive a postcard round trip survives a `MessagePack` one.
#[test]
fn an_untagged_type_round_trips_on_the_self_describing_codec_and_not_the_other() {
    let label = Label {
        text: "12:00".into(),
        width: Some(64),
    };

    let bytes = MessagePack.encode(&label).expect("encode");
    assert_eq!(MessagePack.decode::<Label>(&bytes).expect("decode"), label);

    let bytes = Postcard
        .encode(&label)
        .expect("serializing is fine; only reading back is not");
    assert!(
        matches!(Postcard.decode::<Label>(&bytes), Err(Error::Decode)),
        "postcard has no deserialize_any, so an untagged type cannot be read back"
    );
}

/// The other `deserialize_any` attribute, and the one that answers "capture
/// every key I did not name". `flatten` writes a map of *unknown* length, which
/// some formats refuse outright; `MessagePack` needs the length up front, so
/// `rmp-serde` buffers — the point of the test is that this works rather than
/// erroring, since it is not obvious that it would.
#[test]
fn a_flattened_map_round_trips_on_the_self_describing_codec_and_not_the_other() {
    #[derive(Debug, PartialEq, Serialize, Deserialize)]
    struct Item {
        name: String,
        #[serde(flatten)]
        rest: BTreeMap<String, u32>,
    }

    let item = Item {
        name: "clock".into(),
        rest: BTreeMap::from([("width".to_owned(), 64), ("y_offset".to_owned(), 2)]),
    };

    let bytes = MessagePack.encode(&item).expect("encode");
    assert_eq!(MessagePack.decode::<Item>(&bytes).expect("decode"), item);

    assert!(
        matches!(Postcard.encode(&item), Err(Error::Encode)),
        "postcard cannot even write a map of unknown length"
    );
}

/// `rmp_serde::to_vec` writes a struct as a positional array, which would be
/// just as opaque as postcard and would make the whole change pointless.
/// Decoding into a map is the direct evidence that `to_vec_named` is in use:
/// an array would not decode as one.
#[test]
fn the_self_describing_codec_puts_field_names_on_the_wire() {
    #[derive(Serialize)]
    struct Two {
        first: u8,
        second: u8,
    }

    let bytes = MessagePack
        .encode(&Two {
            first: 1,
            second: 2,
        })
        .unwrap();
    let named: BTreeMap<String, u8> = MessagePack
        .decode(&bytes)
        .expect("a struct written by `to_vec_named` reads back as a map of field names");
    assert_eq!(named["first"], 1);
    assert_eq!(named["second"], 2);

    let positional = rmp_serde::to_vec(&Two {
        first: 1,
        second: 2,
    })
    .unwrap();
    assert!(
        rmp_serde::from_slice::<BTreeMap<String, u8>>(&positional).is_err(),
        "`to_vec` is positional, so this test would pass vacuously if the codec used it"
    );
}

/// Self-description is not free, and the cost is worth knowing rather than
/// guessing at. Printed rather than bounded tightly, so this reports the number
/// instead of becoming a brittle assertion.
#[test]
fn self_description_costs_bytes_and_this_is_how_many() {
    #[derive(Serialize)]
    struct Message {
        item: String,
        label: String,
        width: u32,
        drawing: bool,
    }

    let message = Message {
        item: "clock".into(),
        label: "12:00".into(),
        width: 64,
        drawing: true,
    };
    let compact = Postcard.encode(&message).unwrap().len();
    let described = MessagePack.encode(&message).unwrap().len();
    println!("postcard {compact} bytes, messagepack {described} bytes");
    assert!(described > compact, "field names have to cost something");
}

/// The codec has to reach every value a port touches, not just the first one:
/// the request, the reply and the pushed event are three different types on
/// three different rights, and all three must speak the format the port was
/// created with.
#[test]
fn a_codec_given_at_creation_covers_requests_replies_and_events() {
    /// Both `deserialize_any` attributes at once, so the Mach round trip has
    /// to preserve the self-description rather than merely survive.
    #[derive(Debug, PartialEq, Serialize, Deserialize)]
    struct Set {
        label: Label,
        #[serde(flatten)]
        rest: BTreeMap<String, u32>,
    }

    #[derive(Debug, PartialEq, Serialize, Deserialize)]
    enum Request {
        Set(Set),
        Subscribe,
    }

    #[derive(Debug, PartialEq, Serialize, Deserialize)]
    struct Event {
        seq: u32,
    }

    let name = format!(
        "com.auscyber.async-mach-ports.test.codec.{}",
        std::process::id()
    );
    let receiver = Receiver::<Request, _>::bind(&name, MessagePack).expect("bind");

    let client_name = name.clone();
    let client = std::thread::spawn(move || {
        let sender = loop {
            match Sender::<Request, _>::connect(&client_name, MessagePack) {
                Ok(sender) => break sender,
                Err(Error::NotRunning) => std::thread::yield_now(),
                Err(err) => panic!("connect: {err}"),
            }
        };
        let answer: Set = block_on(sender.call(&Request::Set(Set {
            label: Label {
                text: "12:00".into(),
                width: Some(64),
            },
            rest: BTreeMap::from([("y_offset".to_owned(), 2)]),
        })))
        .expect("a reply");
        let events = block_on(sender.subscribe::<Event>(&Request::Subscribe)).expect("subscribe");
        (answer, block_on(events.recv()).expect("an event").value)
    });

    let delivery = block_on(receiver.recv()).expect("receive");
    let Request::Set(set) = delivery.value else {
        panic!("expected a Set");
    };
    assert_eq!(set.label.width, Some(64));
    assert_eq!(
        set.rest["y_offset"], 2,
        "the flattened keys survived the wire"
    );
    delivery
        .reply
        .expect("a reply channel")
        .send(&set)
        .expect("reply");

    let delivery = block_on(receiver.recv()).expect("receive");
    delivery
        .subscriber
        .expect("a subscriber channel")
        .try_send(&Event { seq: 7 })
        .expect("push");

    let (answer, event) = client.join().expect("the client thread");
    assert_eq!(answer.label.text, "12:00");
    assert_eq!(answer.rest["y_offset"], 2);
    assert_eq!(event, Event { seq: 7 });
}
