# Local transport hardening

Source: async-mach-ports 0.3.0, crates.io, MIT license (see LICENSE).
Upstream repository: https://github.com/auscyber/async-mach-rs
Upstream commit: 842a7245838248dfb2a08ba7a58436fcf6427764.

Local changes cap incoming out-of-line payloads at 4 MiB before copying,
release the mapping and subscriber right on size rejection, make one-shot
replies nonblocking even if a malicious client supplies a full reply port,
and expose subscriber liveness to reclaim slots without sending events.
The wire encoding and normal client protocol remain unchanged.

Use the local source via the Cargo patch. Do not edit the global Cargo cache.
