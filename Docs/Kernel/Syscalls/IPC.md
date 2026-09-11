# IPC and capability syscalls

[Syscall index](README.md) · [Kernel overview](../Overview.md)

Endpoint operations use the [IPC register layout](../../ABI/IPC.md). Message-bearing calls use `x1` for the tag and `x2…x5` for four 32-bit words. Send/reply grant metadata occupies `x6` on input. A receive delivers session and principal metadata in `x6` and `x7`.

`IPCStatus` is returned in `x0`. `.grantRejected` means the message was delivered but its capability grant was not; it is not equivalent to a failed message transfer. Blocking operations may return only after another process or deadline completes the wait.

Capability handles are local to the caller. A successful transfer returns the receiver's new handle, not the sender's handle. See [IPC and capabilities](../IPC.md).

All raw argument/result registers are `UInt64`; narrower payload types are noted below. Pointers are virtual addresses in the caller unless stated otherwise.

| Number | Syscall / implementation | Input | Result |
| --- | --- | --- | --- |
| 15 | [`send`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/SendSyscall.swift) | `x0`: endpoint; message and optional grant registers | `x0`: `IPCStatus`; may block until a receiver is available. |
| 16 | [`receive`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/ReceiveSyscall.swift) | `x0`: endpoint | `x0`: `IPCStatus`; `x1…x7`: delivered message/metadata. May block. |
| 17 | [`spawnEndpoint`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/SpawnEndpointSyscall.swift) | None | `x0`: endpoint handle; `UInt32.max` on failure. |
| 18 | [`call`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/CallSyscall.swift) | `x0`: endpoint; message registers | `x0`: `IPCStatus`; `x1…x7`: reply. Caller waits for the reply. |
| 19 | [`reply`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/ReplySyscall.swift) | `x0`: target identity, or 0 for the current reply relation; message and optional grant registers | `x0`: `IPCStatus`. |
| 20 | [`replyRecv`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/ReplyRecvSyscall.swift) | `x0`: endpoint; reply message registers | `x0`: `IPCStatus`; `x1…x7`: next received message. |
| 21 | [`trySend`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/TrySendSyscall.swift) | `x0`: endpoint; message and optional grant registers | `x0`: `IPCStatus`, including `.wouldBlock` when no receiver is ready. |
| 22 | [`tryReceive`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/TryReceiveSyscall.swift) | `x0`: endpoint | `x0`: `IPCStatus`; message registers valid on delivery. `.wouldBlock` when no sender is ready. |
| 23 | [`receiveTimeout`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/ReceiveTimeoutSyscall.swift) | `x0`: endpoint; `x1`: scheduler ticks | `x0`: `IPCStatus`, including `.timeout`; `x1…x7`: message on delivery. |
| 24 | [`spawnService`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/SpawnServiceSyscall.swift) | None | `x0`: spawn-authority handle; `UInt32.max` on failure. This does not itself launch a service. |
| 25 | [`derive`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/DeriveSyscall.swift) | `x0`: source handle; `x1`: nonzero session badge; `x2`: requested `CapRights` bits | `x0`: new attenuated handle; `UInt32.max` on failure. |
| 31 | [`capExists`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/CapExistsSyscall.swift) | `x0`: handle | `x0`: 1 when a capability is present, otherwise 0. |
| 32 | [`capDrop`](../../../Sources/ReixKernel/Arch/aarch64/Exceptions/Providers/RXIPC/CapDropSyscall.swift) | `x0`: handle | `x0`: 0 on release; `UInt64.max` on failure. |

## Userland API

The [IPC SDK](../../../Sources/Reix/IPC/RXIPC.swift) returns `IPCStatus`, `ReceivedMessage` or `Result<ReceivedMessage, IPCStatus>` depending on the operation. The optional timed-receive wrapper collapses non-`.ok` outcomes to `nil`; use the source contract when an exact failure distinction matters.
