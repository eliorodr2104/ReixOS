# Service protocols

[Documentation home](../README.md) · [Userland services](../Userland/Services.md) · [IPC encoding](IPC.md)

Service protocols define what a receiver does with a message. Their operation labels and payloads are separate from syscall numbers: many different service requests use the same `call` or `send` syscall.

## Contract groups

| Contract | Carries | Responsibility |
| --- | --- | --- |
| [ProcessServer](../../Sources/ReixABI/ProcessServer) | Launch name, status, semantic environment bindings | Application construction and bootstrap handshake. |
| [Block](../../Sources/ReixABI/Block) | Sector ranges, queue slots, geometry, durability and completion | Raw block-device service. |
| [FileSystem](../../Sources/ReixABI/FileSystem) | Object IDs, names, rights, offsets, metadata and statuses | Capability-scoped persistent storage. |
| [NameServer](../../Sources/ReixABI/NameServer) | Registration and lookup messages | Resolve explicitly published service endpoints. |
| [Serial](../../Sources/ReixABI/Serial) | Shared serial-ring state and operations | UART byte transport. |
| [Input](../../Sources/ReixABI/Input) | Input events, sessions and focus operations | Route input to the authorized consumer. |
| [TextSurface](../../Sources/ReixABI/TextSurface) | Semantic text operations, rings and text-width support | Terminal presentation shared by producers and adapter. |
| [Shell](../../Sources/ReixABI/Shell) | Typed values, output records, completion/panel contracts | Shell/application interaction. |
| [Session](../../Sources/ReixABI/Session) | Session-control operations | Coordination outside the one-time bootstrap channel. |
| [IPC pipe and attachments](../../Sources/ReixABI/IPC) | Pipe protocol and shared attachment policy | Transfer larger data under an agreed shared-memory contract. |

## Application bootstrap

`ProcessLaunchRequest` carries at most **12 name bytes**. Its launch operation is `0x720`; the payload uses one word for length and three words for the bytes. The current launcher also checks `ProgramProfile`; a syntactically valid name is not permission to launch any arbitrary file.

The environment transaction starts at label `0x730`, uses version **1**, and allows up to **16 bindings**. It sends `begin`, ordered `binding` messages with grants, acknowledgements, then `commit`. The child sends `ready` when its initialization reaches the readiness point. A nonce binds the exchange; indexes bind acknowledgements to individual steps.

Bindings name roles such as console, programs directory or input consumer. Their role does not depend on the received handle's table slot. See [Process launch](../Userland/ProcessLaunch.md).

## Block and filesystem sessions

`BlockQueue` has **4 slots**. A completion identifies the slot whose shared window is ready; the client must not treat submission as completion. Geometry reports sector size/count and durability support. The current virtio driver uses 512-byte sectors; RxFS uses 4096-byte blocks above that interface.

The block endpoint distinguishes disk, read-only diagnostic and warden badges. Mount ownership governs raw access. FileSystemServer receives the writable disk endpoint and exposes narrower object/container capabilities to its clients.

Filesystem operations carry `FSRights` in their service authority model, distinct from the kernel's `CapRights`. A send-capable endpoint is necessary to reach the server, but the server still checks the requested filesystem operation against its session/object rights.

## Evolving a contract

Update the producer, receiver and shared encoding together. Check tag length, word interpretation, shared-buffer bounds and ownership on error paths. For a disk-layout change, also account for existing bytes on disk; changing a Swift struct is not a migration.
