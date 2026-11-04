# Userland and the Reix SDK

[Documentation home](../README.md) · [Services](Services.md) · [System map](../Architecture/System.md)

Userland supplies the services and applications above the kernel. `Reix` is the native SDK linked into those programs. It wraps syscalls, provides allocation/runtime support and implements clients for service protocols.

The SDK is not a separately scheduled server. `ReixABI` supplies shared contracts, while `ReixFS` and `ProcessServerCore` supply reusable algorithms behind particular services.

## Build layers

| Module | Depends on | Purpose |
| --- | --- | --- |
| `ReixABI` | No project module | Shared numbers, layouts and protocol values. |
| `Heap` | No project module | Shared slab allocator and backend contract. |
| `Text` | No project module | Unicode tables and text/editor layout. |
| `MemoryPrimitives` | No project module | Portable, aligned `RawBytes` memory operations. |
| `VirtioBlockCore` | `ReixABI` | Pure block-driver queue, capacity and completion rules. |
| `Reix` | `ReixABI`, `Heap`, `MemoryPrimitives` | Syscalls, memory/runtime support, IPC, clients and service boot helpers. |
| `ReixFS` | `ReixABI` | Filesystem algorithm over a generic `BlockDevice`. |
| `ProcessServerCore` | `ReixABI` | Bounded ELF planning/copying, program profiles and resumable launch supervision. |
| `SerialServerCore` / `InputServerCore` | `Reix`, `ReixABI` | Serial/input rings, sessions and server policy. |
| `TerminalCore` | `Reix`, `ReixABI`, `Text` | Semantic screen model, VT renderer/decoder and terminal session. |
| `ShellLanguage` | `ReixABI`, `Text` | Parsing, values, semantic analysis, catalog and completion. |
| `LineEditor` | `ShellLanguage`, `ReixABI`, `Text` | Editing, key mapping, panels and editor presentation. |
| Userland programs | `Reix`, plus their domain modules | Service loops and applications. |

The freestanding build enables Embedded Swift and supplies assembly/runtime boundaries through the `reix` CLI in `Tools/reix`. See [Package.swift](../../Package.swift) for actual target dependencies.

## SDK and service support

| Block | API / state | What callers need to understand |
| --- | --- | --- |
| [Task wrappers](../../Sources/SDK/Syscalls/RXTask.swift) | `SpawnResult`, `TaskCreation`, `TaskStatus` | Bootstrap spawn differs from controlled application launch. |
| [Memory](../../Sources/SDK/Memory) and [heap](../../Sources/SDK/Heap) | `SharedMemory`, `DmaBuffer`, allocation backend | A local address, capability ownership and physical backing are different resources. |
| [IPC](../../Sources/SDK/IPC) | `ReceivedMessage`, pipes, calls/replies | Blocking behavior, delivery status and grant lifetime. |
| [Service clients](../../Sources/SDK/Clients) | Block, filesystem, process, name and console clients | Each server owns its operation protocol. |
| [Terminal surfaces](../../Sources/Userland/OS/Terminal/TerminalCore), [input](../../Sources/Userland/System/InputServerCore), [serial](../../Sources/Userland/System/SerialServerCore) | Shared rings and client state | Producer/consumer roles, notification and presentation ownership. |
| [Profiling](../../Sources/SDK/Profile) and [time](../../Sources/SDK/Time) | Authority-scoped observation and clock wrappers | Units, authority and operation-specific results. |
| Runtime, formatting and memory helpers | Freestanding support functions | Local implementation support, not additional kernel services. |

Server and terminal implementations are separate modules beside their executables. The SDK supplies their syscall, client and runtime building blocks.

The SDK's `memcpy`, `memset` and `memmove` use `MemoryPrimitives.RawBytes`, shared with the kernel. Its portable Swift SIMD paths keep accesses naturally aligned, including before the MMU is enabled. Only the kernel adds a `dc zva` zero-fill path; userland uses the shared fill. See [memory primitives](../Kernel/Memory.md#memory-primitives).

## Resource-bearing values

| Type | Fields | Meaning |
| --- | --- | --- |
| `SharedMemory` | `handle: UInt32`, `address: UInt64`, computed `isValid` | A region capability and its local mapping. |
| `DmaBuffer` | `handle: UInt32`, `address: UInt64`, computed `isValid` | DMA allocation capability and local mapping; physical address is queried separately. |
| `SpawnResult` | `pid: PID`, `handle: UInt32`, computed `hasEndpoint` | Bootstrap spawn result and parent-side endpoint. |
| `ProcessLaunchResult` | `status: ProcessServerStatus`, `job: UInt32?` | Ordinary application launch result. |
| `Environment` | Optional handles named by role | Capabilities available to the program, acquired from bootstrap slots or a dynamic transaction. |

These wrappers are not an automatic ownership system for arbitrary copied handles. The code that receives or takes a capability must define when to release it.

## Service startup

`Environment.boot()` discovers the program's environment. `ServiceManifest` describes whether a service publishes an endpoint to its parent; the runtime handles the common startup path and dispatches messages through `UserlandService`/`Service`.

`Environment.signalReady() -> Bool` completes the dynamic readiness handshake when one exists. A service-specific initialization failure must be reflected before publishing readiness.

## Concurrency boundary

Today, blocking SDK calls block the native process executing them. The proposed `rxTask`/M:N runtime would live above native kernel execution in userland. It is not implemented by these wrappers, and ordinary Swift syntax does not imply the presence of a Swift Concurrency executor. See [Concurrency](../Concurrency.md).
