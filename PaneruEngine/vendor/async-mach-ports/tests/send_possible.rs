//! Reproduces the hang in `Subscriber::send`'s wait path: fill a subscriber's
//! port past its depth, then await a send that has to wait for room.
//!
//! Self-bounding throughout -- a `recv_timeout` on the awaited send's result
//! means a regression fails the test rather than hanging the suite.

mod support;

use async_mach_ports::{Error, Receiver, RecvPort, SendPort, Sender};
use futures_lite::StreamExt;
use futures_lite::future::block_on;
use serde::{Deserialize, Serialize};
use std::sync::mpsc;
use std::time::Duration;
use support::Postcard;

#[derive(Debug, PartialEq, Serialize, Deserialize)]
enum Request {
    Subscribe,
}

#[derive(Debug, PartialEq, Serialize, Deserialize)]
struct Event {
    seq: u32,
}

fn service_name(test: &str) -> String {
    format!(
        "com.auscyber.async-mach-ports.test.{test}.{}",
        std::process::id()
    )
}

fn connect<T: Serialize>(name: &str) -> Sender<T, Postcard> {
    loop {
        match Sender::connect(name, Postcard) {
            Ok(sender) => return sender,
            Err(Error::NotRunning) => std::thread::yield_now(),
            Err(err) => panic!("connect: {err}"),
        }
    }
}

#[test]
fn send_waits_for_room_instead_of_hanging() {
    let name = service_name("sendpossible");
    let receiver = Receiver::<Request, _>::bind(&name, Postcard).expect("bind");

    // The client subscribes immediately, but only drains on a signal from the
    // main thread -- that is what lets the queue be driven to WouldBlock
    // before anything frees a slot in it. It also keeps its receiver alive
    // until told it may stop: dropping it deallocates the receive right the
    // subscriber's send right names, and doing that the instant a slot frees
    // up races the very retry that slot was supposed to unblock.
    let (go_tx, go_rx) = mpsc::channel::<()>();
    let (done_tx, done_rx) = mpsc::channel::<()>();
    let client_name = name.clone();
    let client = std::thread::spawn(move || {
        let sender = connect::<Request>(&client_name);
        let mut events =
            block_on(sender.subscribe::<Event>(&Request::Subscribe)).expect("subscribe");
        go_rx.recv().expect("main thread signals when to drain");
        let event = block_on(events.next()).expect("a stream item").expect("ok");
        done_rx.recv().expect("main thread releases the receiver");
        event
    });

    let delivery = block_on(receiver.recv()).expect("receive");
    let subscriber = delivery.subscriber.expect("a subscriber channel");

    // Fill the subscriber's queue with `try_send`, which never waits, until
    // the kernel reports it full.
    let mut filled = 0u32;
    loop {
        match subscriber.try_send(&Event { seq: filled }) {
            Ok(()) => {
                filled += 1;
                assert!(filled < 1000, "queue never filled -- something is off");
            }
            Err(Error::WouldBlock) => break,
            Err(err) => panic!("unexpected try_send failure: {err}"),
        }
    }
    eprintln!("queue accepted {filled} events before WouldBlock");
    assert!(
        filled > 0,
        "the queue must accept at least one event to be meaningful"
    );

    // Now await a send into the still-full queue, on its own thread so the
    // main thread can bound the wait rather than hang with it.
    let (result_tx, result_rx) = mpsc::channel();
    std::thread::spawn(move || {
        let result = block_on(subscriber.send(&Event { seq: filled }));
        let _ = result_tx.send(result);
    });

    // Give the pending send a chance to request its notification before a
    // slot opens -- otherwise the drain below could race ahead of it.
    std::thread::sleep(Duration::from_millis(300));
    go_tx.send(()).expect("the client thread is waiting on it");

    let outcome = result_rx.recv_timeout(Duration::from_secs(10));
    // Release the client's receiver now that the send has settled one way or
    // the other, regardless of what follows.
    done_tx.send(()).expect("client is waiting to be released");

    let result = outcome.expect(
        "Subscriber::send hung waiting for room -- MACH_NOTIFY_SEND_POSSIBLE never resolved it",
    );
    result.expect("the waited send should succeed once a slot opened");

    client.join().expect("client thread");
}
