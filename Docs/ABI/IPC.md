# IPC encoding and delivery

[Documentation home](../README.md) · [IPC syscalls](../Kernel/Syscalls/IPC.md) · [Kernel IPC](../Kernel/IPC.md)

IPC carries a small register message and optional capability transfer. Large payloads use a separately granted shared-memory region. The receiver must validate both the operation message and the authority/lifetime of any attached region.

## Message registers

| Register | On send/reply input | On receive output |
| --- | --- | --- |
| `x0` | Endpoint handle, or reply target identity | `IPCStatus` |
| `x1` | Packed tag | Packed tag |
| `x2…x5` | Four zero-extended `UInt32` words | Four zero-extended `UInt32` words |
| `x6` | Optional grant: rights in upper 32 bits, handle in lower 32 bits | Full 64-bit session badge |
| `x7` | Not part of the ordinary send arguments | Sender identity in upper 32 bits, granted handle in lower 32 bits |

The tag is `(UInt64(label) << 8) | UInt64(length)`. `length` counts meaningful message words, not bytes. The four-word storage provides 16 payload bytes; the Swift `Message` object itself is not specified as a tightly packed 21-byte buffer.

`UInt32.max` means no granted capability. Slot zero is valid and must not be interpreted as absence. Input and output `x6` have different meanings.

Timed receive uses `x1` as its input timeout; the delivered tag replaces it on output. The assembly wrappers preserve all result registers needed by `ReceivedMessageRaw`.

## Delivery outcomes

| Status | Value | Interpretation |
| --- | --- | --- |
| `ok` | 0 | Message delivered. |
| `wouldBlock` | 1 | No immediate match. |
| `notEnoughRights` | 2 | Authority lacks a required right. |
| `invalidCapability` | 3 | Handle/target is unsuitable. |
| `timeout` | 4 | Wait expired. |
| `noReply` | 5 | No matching reply relation. |
| `invalidMessage` | 6 | Invalid message or operation encoding. |
| `outOfEndpoints` | 7 | Endpoint capacity unavailable. |
| `peerDied` | 8 | Peer termination prevented completion. |
| `grantRejected` | 9 | Message delivered, capability transfer rejected. |

`IPCStatus.isDelivered` is true for `ok` and `grantRejected`. A caller requiring the grant must check for it separately.

## Userland ownership

| API | Parameters | Returns | Meaning |
| --- | --- | --- | --- |
| `send` | `handle: UInt32`, `message: Message`, optional grant and `CapRights` | `IPCStatus` | Sends or waits for a receiver. |
| `receive` | `handle: UInt32` | `ReceivedMessage` | Message plus delivery status, sender, badge and optional grant. |
| `receive` with timeout | `handle: UInt32`, `timeout: UInt32` ticks | `ReceivedMessage?` | The wrapper returns a value only for `.ok`; other outcomes become `nil`. |
| `call` | `handle: UInt32`, `message: Message` | `Result<ReceivedMessage, IPCStatus>` | Waits for a reply; delivered outcomes are successful values. |
| `ReceivedMessage.takeGrant()` | None | `UInt32?` | Returns and clears the wrapper's grant field. It does not drop the capability. |
| `capDrop` | Handle `UInt32` | `Bool` | Releases the process's capability reference. |

`ReceivedMessage` stores `message`, `status`, `identity: UInt32`, `session: UInt64` and `grantedCap: UInt32?`. Consumers that take a grant become responsible for its subsequent use or release. Copying this value is not an automatic kernel reference-count operation.

Some convenience wrappers discard raw status distinctions: the current `replyRecv` and `tryReceive` implementations do not preserve every error in the returned wrapper. Their source is authoritative when a caller needs exact outcomes.

## Shared memory and interrupt notifications

Shared-memory handles authorize mapping an existing region; a write mapping requires write authority. The mapping address is local to each process and is not a portable IPC pointer. Ring protocols add their own cursor, epoch/session and ownership rules on top of that mapping.

Interrupt notifications are recognized by the `InterruptNotification` contract, including kernel-origin metadata. They carry interrupt-set bits; they are not arbitrary messages with a user-chosen label alone.

## Source entry points

[Message](../../Sources/ReixABI/IPC/Message.swift), [tag packing](../../Sources/ReixABI/IPC/MessageTag.swift), [delivery metadata](../../Sources/ReixABI/IPC/IPCDelivery.swift), [status](../../Sources/ReixABI/IPC/IPCStatus.swift), [SDK wrappers](../../Sources/Reix/IPC/RXIPC.swift), [received-message ownership](../../Sources/Reix/IPC/ReceivedMessage.swift), [trap-frame conversion](../../Sources/ReixKernel/InterProcessControl/Endpoints/Message+Frame.swift).
