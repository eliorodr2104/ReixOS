# Service protocols

[Documentation home](../README.md) · [Userland services](../Userland/Services.md) · [IPC encoding](IPC.md)

Service protocols define what a receiver does with a message. Their operation labels and payloads are separate from syscall numbers: many different service requests use the same `call` or `send` syscall.

## Contract groups

| Contract | Carries | Responsibility |
| --- | --- | --- |
| [ProcessServer](../../Sources/ABI/ProcessServer) | Launch name, status, semantic environment bindings | Application construction and bootstrap handshake. Statuses include `busy` for a claimed program file or duplicate pending requester, and `timedOut` for an expired launch. |
| [Block](../../Sources/ABI/Block) | Sector ranges, queue slots, geometry, durability and completion | Raw block-device service. |
| [FileSystem](../../Sources/ABI/FileSystem) | Object IDs, names, rights, offsets, metadata and statuses | Capability-scoped persistent storage. |
| [NameServer](../../Sources/ABI/NameServer) | Registration and lookup messages | Resolve explicitly published service endpoints. |
| [Serial](../../Sources/ABI/Serial) | Shared serial-ring state and operations | UART byte transport. |
| [Input](../../Sources/ABI/Input) | Input events, sessions and focus operations | Route input to the authorized consumer. |
| [TextSurface](../../Sources/ABI/TextSurface) | Semantic text operations, rings and text-width support | Terminal presentation shared by producers and adapter. |
| [Shell](../../Sources/ABI/Shell) | Typed values, output records, completion/panel contracts | Shell/application interaction. |
| [Session](../../Sources/ABI/Session) | Session-control operations | Coordination outside the one-time bootstrap channel. |
| [IPC pipe and attachments](../../Sources/ABI/IPC) | Pipe protocol and shared attachment policy | Transfer larger data under an agreed shared-memory contract. |

## Application bootstrap

`ProcessLaunchRequest` carries at most **12 name bytes**. Its launch operation is `0x720`; the payload uses one word for length and three words for the bytes. The current launcher also checks `ProgramProfile`; a syntactically valid name is not permission to launch any arbitrary file.

`ProcessServerStatus` is returned in word 0 of a one-word launch response:

| Value | Status | Meaning |
| --- | --- | --- |
| 0 | `ok` | The child reached `Ready`; the response grants an attenuated job capability. |
| 1 | `badRequest` | Invalid name/profile, sender or unexpected grant. |
| 2 | `notFound` | The program file cannot be opened or no longer exists. |
| 3 | `malformedELF` | The claimed program has no valid supported ELF plan. |
| 4 | `capacity` | Four launches are already pending, or eight pending/supervised jobs are reserved. |
| 5 | `taskFailure` | Task construction or copying failed. |
| 6 | `bootstrapFailure` | The environment exchange failed, including a child dying during bootstrap. |
| 7 | `unavailable` | Required bindings, filesystem access or a usable deadline are unavailable. |
| 8 | `busy` | The program file is claimed by another client, or this sender identity already has a pending launch. |
| 9 | `timedOut` | The absolute launch deadline expired; cleanup has run and any still-stopping job remains supervised. |

The production launch budget is five seconds from acceptance, including the loader queue; it is never reset by progress. Up to four launches interleave through deferred replies addressed to the original caller's identity. See [launch supervision](../Userland/ProcessLaunch.md#resumable-launch-and-cleanup) for cleanup and the synchronous-filesystem limitation.

The environment transaction starts at label `0x730`, uses version **1**, and allows up to **16 bindings**. It sends `begin`, ordered `binding` messages with grants, acknowledgements, then `commit`. The child sends `ready` when its initialization reaches the readiness point. A nonce binds the exchange; indexes bind acknowledgements to individual steps.

Bindings name roles such as console, programs directory or input consumer. Their role does not depend on the received handle's table slot. See [Process launch](../Userland/ProcessLaunch.md).

## Block and filesystem sessions

`BlockQueue` has **4 slots**. A completion identifies the slot whose shared window is ready; the client must not treat submission as completion. Geometry reports sector size/count and durability support. The current virtio driver uses 512-byte sectors; RxFS uses 4096-byte blocks above that interface.

The block endpoint distinguishes disk, read-only diagnostic and warden badges. Mount ownership governs raw access. FileSystemServer receives the writable disk endpoint and exposes narrower object/container capabilities to its clients.

Filesystem operations carry `FSRights` in their service authority model, distinct from the kernel's `CapRights`. A send-capable endpoint is necessary to reach the server, but the server still checks the requested filesystem operation against its session/object rights.

### `FSRights` and the badge

`FSRights` is a nine-bit set. A capability is minted from another one and takes the intersection of the rights, so authority only narrows downhill. `FSRights.required(for:)` holds the whole matrix; `attach` and `status` need no right.

| Right | Bit | Operations |
| --- | --- | --- |
| `lookup` | 0 | `open`, `list`, `up`, `path`, `info`. |
| `read` | 1 | `read`. |
| `write` | 2 | `create`, `write`, `replace`, `compact`; with `quota`, `createContainer`. |
| `remove` | 3 | `remove`, `relocate`. |
| `delegate` | 4 | `bind`. |
| `quota` | 5 | `grantRoom`; with `write`, `createContainer`. |
| `admin` | 6 | `nameMachine`, `scrub`. |
| `unmount` | 7 | `unmount`. |
| `claim` | 8 | `lock`, `unlock`. |

`claim` is separate from `write` so that a reader of a file can keep it still without being able to rewrite it. A claim makes the server refuse every other client's change to that file, with `busy` and never a wait; a claim whose holder has died is swept before the refusal is given. The presets are:

| Preset | Rights |
| --- | --- |
| `everything` | All nine. The machine's own container. |
| `reader` | `lookup`, `read`. It has no `claim`: a read-only loan into someone else's container must not be able to freeze the file it was lent. |
| `occupant` | `lookup`, `read`, `write`, `remove`, `claim`. A container of its own, with nothing to hand away or administer; `claim` is there because `FileSystemClient.replaceAll` claims the file around its writes. |
| `loader` | `lookup`, `read`, `claim`. What ProcessServer holds on the program folder: it can read a program and hold it still, never write it. |

The session badge is 64 bits: the rights in the top nine, the object slot plus one in the low bits, and the object's generation between them, capped at 32 bits. The generation is checked on every request, so a capability cannot name a different file that reused its slot. `FSStatus.busy` is also what a refused change to a claimed file answers.

Filesystem reads can return `FSStatus.damaged` when a file block fails its checksum, with progress ending before that block. This leaves the volume serviceable; a table, folder or sum-region contradiction instead quarantines it. `tooManyChanges` also covers writes exceeding the bounded overwrite declaration. See [storage integrity](../Architecture/Storage.md#integrity-checks-and-the-seal).

The shell scrub response uses `ShellFindingsFrame`: 21 ordered fields, ending in `damagedBlocks` (field ID 23). `scrubDepth` distinguishes blocks (0), metadata (1) and data (2). `safeToServe` does not imply zero damaged file blocks. See [scrub results](../Userland/Storage.md#scrub-results).

## Evolving a contract

Update the producer, receiver and shared encoding together. Check tag length, word interpretation, shared-buffer bounds and ownership on error paths. For a disk-layout change, also account for existing bytes on disk; changing a Swift struct is not a migration.
