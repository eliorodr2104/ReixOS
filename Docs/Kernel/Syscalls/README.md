# Syscalls

[Documentation home](../../README.md) · [Kernel overview](../Overview.md) · [ABI](../../ABI/README.md)

A syscall enters EL1 through AArch64 `svc`. The caller places the operation number in `x8`; arguments occupy `x0…x6` according to the operation. Results normally use `x0`, with additional registers for messages and multi-value returns.

The **57 current syscall numbers** are declared in [SyscallNumber.swift](../../../Sources/ReixABI/SyscallNumber.swift). Their raw values are implicit and follow declaration order. Kernel and userland must agree on that order; these docs do not promise compatibility after renumbering.

## By operation

| Group | Covers |
| --- | --- |
| [Processes and tasks](Processes.md) | Bootstrap spawn, process lifetime, sleep, suspended configuration and job control. |
| [Memory](Memory.md) | Program break, anonymous mappings, retirement, shared memory and DMA allocations. |
| [IPC and capabilities](IPC.md) | Endpoint communication, calls/replies, deadlines, derivation and release. |
| [Devices and interrupts](Devices.md) | MMIO access, bus-derived authority, IRQ wait/bind/ack. |
| [Time, diagnostics and power](System.md) | Clock, profiler/statistics, kernel-console byte and shutdown. |

## Dispatch and validation

```mermaid
flowchart LR
    SDK[Reix SDK wrapper] --> ASM[Assembly shim]
    ASM -->|svc / x8| EX[Exception handler]
    EX --> DIS[SyscallHandler]
    DIS --> PROVIDER[Operation provider]
    PROVIDER --> AUTH[Validate arguments / authority]
    AUTH --> BLOCK[Kernel subsystem]
    BLOCK --> RESULT[Saved result registers]
```

The exception handler rejects unknown syscall numbers. `SyscallHandler` builds a `SyscallContext` with the process, scheduler, IPC and physical-memory managers and dispatches to the provider. Each provider validates its own pointers, bounds, state and rights.

A provider's Swift `handle` method returning `Void` does **not** mean the syscall has no result. The result is written into the saved trap frame, sometimes later when a blocked operation completes.

## Reading the tables

Each operation links directly to its implementation. Input and result columns describe the raw register ABI; userland wrappers may convert sentinels to optionals, booleans or typed statuses. Error conventions are operation-specific. Do not assume a Unix `errno` contract or a single failure sentinel.

The [IPC ABI](../../ABI/IPC.md) defines the register-packed message format. [Process launch](../../Userland/ProcessLaunch.md) explains how several task syscalls form one application launch.
