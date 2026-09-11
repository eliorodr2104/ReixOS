# ABI and shared contracts

[Documentation home](../README.md) · [Syscalls](../Kernel/Syscalls/README.md)

`ReixABI` is compiled into the kernel and userland targets that need shared contracts. It defines syscall numbers, IPC encoding, rights, status values and service protocols. It also contains reusable support code; being in this module does not automatically make a Swift type a wire format.

## Three boundaries

| Boundary | Contract | Where to read it |
| --- | --- | --- |
| EL0 ↔ EL1 | Syscall numbers, argument/result registers, capability checks | [Syscalls](../Kernel/Syscalls/README.md) |
| Process ↔ process | Message labels/words, badges, grants and shared-memory protocols | [IPC](IPC.md), [service protocols](Services.md) |
| Memory ↔ disk | Explicit block offsets, record encoding and persistence ordering | [RxFS disk layout](../Architecture/Storage.md) |

A service message is transported by kernel IPC, but its operation label is interpreted by the receiving service. The kernel does not implement a filesystem operation merely because `FileOperation` lives in the shared module.

## Values shared with the kernel

| Definition | Representation | Meaning |
| --- | --- | --- |
| `SyscallNumber` | `UInt64` enum | Operation placed in `x8`; current values follow declaration order. |
| Capability handle | `UInt32` | Caller-local table slot. |
| `CapRights` | `UInt16` option set | Rights interpreted against the capability target. |
| `CapGrant` | Three `UInt32` fields | Source handle, destination slot and rights for bootstrap injection. |
| `MessageTag` | `UInt32` label + `UInt8` length | Encoded explicitly into one register. |
| `Message` | Four `UInt32` words + tag | Small IPC payload; not copied as an assumed packed Swift struct. |
| `TaskResult`, `TaskState` | `UInt64` enums | Configuration outcome and observable task state. |
| `TaskABI` | Shared constants | Page size, user address range and configuration limits. |
| `SchedulerABI` | Shared constant | 10 ms per scheduler tick. |
| `FaultCause` and process/statistics types | Shared typed values/layouts | Fault reporting and requested observation data. |

`BootCap` names bootstrap slots. Dynamically received capabilities can occupy other free slots; `EnvironmentBinding` supplies their semantic role. A handle's numeric value alone is not a service identity.

## Layout and compatibility

Explicit register packing and byte-offset encoders define the corresponding transport format. Native Swift size, stride and alignment must not be guessed from the sum of fields. Shared statistics/ring layouts have their own headers and layout checks.

Changes to syscall ordering, status values, message labels or shared layouts require matching producer and consumer changes. There is no blanket stable-ABI promise here. Individual protocols define versions where implemented, such as environment transaction version 1 and RxFS format `02`.

`SlabCore`/`SlabBackend` are shared allocator support. Unicode/text helpers and shell values similarly support consumers without becoming kernel mechanisms.

## Source entry points

- [Syscall numbers](../../Sources/ReixABI/SyscallNumber.swift), [capabilities](../../Sources/ReixABI/Capabilities), [task contracts](../../Sources/ReixABI/Task).
- [IPC contracts](../../Sources/ReixABI/IPC), [statistics](../../Sources/ReixABI/ProcessStats), [profiler](../../Sources/ReixABI/Profiler), [time](../../Sources/ReixABI/Time).
- [ABI layout tests](../../Tests/ABILayoutTests), [shared module](../../Sources/ReixABI).
