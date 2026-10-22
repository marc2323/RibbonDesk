//! Where requests from other processes come in.
//!
//! Paneru publishes a Mach service under a well-known name; the CLI, the
//! loadable Lua module and anything else that wants to drive the window manager
//! connect to that name and send it a [`Request`]. Each one is turned into an
//! [`Event`] for the world, and the ones that expect an answer carry a reply
//! channel the answering system fills in.

use crate::types::wire::{self, Delivery, Reply as MachReply, Request, service_name};
use bevy::tasks::{IoTaskPool, TaskPool};
use futures_lite::StreamExt;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};
use tracing::{debug, error, warn};

const MAX_PENDING_IPC: usize = 64;
const MAX_LAYOUT_OPERATIONS: usize = 4096;
type IpcPermit = Arc<async_lock::SemaphoreGuardArc>;

use crate::errors::Result;
use crate::events::{Event, EventSender, Reply};

/// `CommandReader` owns the service port and feeds what arrives on it into the
/// world.
pub struct CommandReader {
    events: EventSender,
}

impl CommandReader {
    /// Creates a new `CommandReader`.
    ///
    /// # Arguments
    ///
    /// * `events` - An `EventSender` to dispatch received requests on.
    #[must_use]
    pub fn new(events: EventSender) -> Self {
        CommandReader { events }
    }

    /// Claims the service name and starts serving it on a thread of its own.
    ///
    /// # Errors
    ///
    /// Returns an error if another Paneru daemon already owns the name.
    pub fn start(self) -> Result<()> {
        let receiver = wire::bind::<Request>(&service_name()).inspect_err(|_| {
            error!(
                "can not register a Mach port - maybe another Paneru instance is already running?"
            );
        })?;

        thread::spawn(move || {
            // Parks this one thread for the process lifetime; each request is
            // handed to the IO pool rather than served inline.
            futures_lite::future::block_on(async move {
                let mut requests = std::pin::pin!(receiver);
                let limit = Arc::new(async_lock::Semaphore::new(MAX_PENDING_IPC));
                let mut last_warning: Option<Instant> = None;
                loop {
                    // Stop receiving when full; Mach applies backpressure to
                    // clients while native input keeps its independent channel.
                    let permit = Arc::new(limit.acquire_arc().await);
                    let Some(delivery) = requests.next().await else {
                        break;
                    };
                    match delivery {
                        Ok(delivery) => self.dispatch(delivery, permit),
                        // A request that fails to decode is a bad client, not a
                        // reason to stop serving.
                        Err(err) => {
                            if last_warning
                                .is_none_or(|last| last.elapsed() >= Duration::from_secs(5))
                            {
                                warn!("reading request: {err} (further errors suppressed for 5s)");
                                last_warning = Some(Instant::now());
                            }
                        }
                    }
                }
            });
        });

        Ok(())
    }

    /// Turns one request into an event, and arranges for its answer.
    fn dispatch(&self, delivery: Delivery<Request>, permit: IpcPermit) {
        let events = self.events.clone();
        let Delivery {
            value,
            reply,
            subscriber,
        } = delivery;

        if matches!(&value,
            Request::WindowSetApply(ops) | Request::Command(crate::commands::Command::Layout(ops))
                if ops.len() > MAX_LAYOUT_OPERATIONS)
        {
            debug!("ignoring oversized layout operation batch");
            return;
        }
        match value {
            // Fire-and-forget: no reply is sent for this request.
            Request::Command(command) => {
                send(&events, &permit, Event::Command { command });
            }
            Request::WindowSetApply(ops) => {
                send(
                    &events,
                    &permit,
                    Event::Command {
                        command: crate::commands::Command::Layout(ops),
                    },
                );
            }

            Request::Query(kind) => {
                answer(events, permit, reply, "state query", move |respond_to| {
                    Event::StateQuery { kind, respond_to }
                });
            }
            Request::WindowSet => {
                answer(events, permit, reply, "window set query", |respond_to| {
                    Event::WindowSetQuery { respond_to }
                });
            }
            Request::ScriptState(request) => {
                answer(
                    events,
                    permit,
                    reply,
                    "script state request",
                    move |respond_to| Event::ScriptState {
                        request,
                        respond_to,
                    },
                );
            }

            Request::Subscribe => {
                if let Some(subscriber) = subscriber {
                    send(
                        &events,
                        &permit,
                        Event::StateSubscribe {
                            subscriber: Arc::new(subscriber),
                        },
                    );
                } else {
                    // No channel to push events to; the sender built the
                    // request by hand and got it wrong.
                    debug!("subscribe request carried no event channel");
                }
            }
        }
    }
}

/// Sends an event that expects no answer.
fn send(events: &EventSender, permit: &IpcPermit, event: Event) {
    _ = events
        .send(Event::Ipc {
            event: Box::new(event),
            permit: Arc::clone(permit),
        })
        .inspect_err(|err| error!("sending event: {err}"));
}

/// Sends a request-carrying event to the world and answers the client with
/// whatever comes back. `what` only names the request in the log.
///
/// The wait runs on the IO pool, not the receive loop, so a slow client blocks
/// only itself. There is no timeout: the reply sender travels inside the
/// event, so if the world never answers, the event is dropped, the channel
/// closes, and `recv` resolves anyway.
fn answer(
    events: EventSender,
    permit: IpcPermit,
    reply: Option<MachReply>,
    what: &'static str,
    request: impl FnOnce(Reply) -> Event + Send + 'static,
) {
    let Some(reply) = reply else {
        debug!("{what} arrived without a reply channel");
        return;
    };

    let (tx, rx) = async_channel::bounded(1);
    if events
        .send(Event::Ipc {
            event: Box::new(request(tx)),
            permit: Arc::clone(&permit),
        })
        .inspect_err(|err| error!("sending {what}: {err}"))
        .is_err()
    {
        return;
    }

    // `get_or_init`, not `get`: the reader starts before the Bevy app is built,
    // so an early client would otherwise find no pool at all and panic.
    IoTaskPool::get_or_init(TaskPool::default)
        .spawn(async move {
            let _permit = permit;
            match rx.recv().await {
                Ok(response) => {
                    match reply.send(&response) {
                        // Client exit and a deliberately full reply port must
                        // neither block a worker nor flood the log.
                        Ok(()) | Err(wire::Error::PeerGone | wire::Error::WouldBlock) => {}
                        Err(err) => warn!("answering {what}: {err}"),
                    }
                }
                Err(err) => error!("waiting for {what} response: {err}"),
            }
        })
        .detach();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ipc_backlog_is_bounded_without_blocking_native_events() {
        let limit = Arc::new(async_lock::Semaphore::new(MAX_PENDING_IPC));
        let (events, incoming) = EventSender::new();
        for _ in 0..MAX_PENDING_IPC {
            let permit = Arc::new(limit.try_acquire_arc().expect("capacity"));
            send(
                &events,
                &permit,
                Event::Command {
                    command: crate::commands::Command::Quit,
                },
            );
        }
        assert!(limit.try_acquire_arc().is_none());
        events.send(Event::ProcessesLoaded).unwrap();
        let first = incoming.try_recv().unwrap().unwrap_ipc();
        assert!(matches!(
            first,
            Event::Command {
                command: crate::commands::Command::Quit
            }
        ));
        assert!(
            limit.try_acquire_arc().is_some(),
            "processing returns IPC capacity"
        );
        for _ in 1..MAX_PENDING_IPC {
            incoming.try_recv().unwrap();
        }
        assert!(matches!(
            incoming.try_recv().unwrap(),
            Event::ProcessesLoaded
        ));
    }

    #[test]
    fn oversized_layout_batch_is_rejected_before_entering_the_event_queue() {
        let (events, incoming) = EventSender::new();
        let reader = CommandReader::new(events);
        let limit = Arc::new(async_lock::Semaphore::new(1));
        reader.dispatch(
            Delivery {
                value: Request::WindowSetApply(vec![
                    crate::types::windowset::LayoutOp::Focus(7);
                    MAX_LAYOUT_OPERATIONS + 1
                ]),
                reply: None,
                subscriber: None,
            },
            Arc::new(limit.try_acquire_arc().unwrap()),
        );
        assert!(incoming.try_recv().is_err());
        assert!(limit.try_acquire_arc().is_some());
    }
}
