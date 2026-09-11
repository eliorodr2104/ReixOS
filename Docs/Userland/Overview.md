# Userland and the Reix SDK

[Documentation home](../README.md) · [Services](Services.md) · [System map](../Architecture/System.md)

Userland supplies the services and applications above the kernel. `Reix` is the native SDK linked into those programs. It wraps syscalls, provides allocation/runtime support and implements clients for service protocols.

The SDK is not a separately scheduled server. `ReixABI` supplies shared contracts, while `ReixFS` and `ProcessServerCore` supply reusable algorithms behind particular services.

## Build layers

| Module | Depends on | Purpose |
| --- | --- | --- |
| `ReixABI` | No project module | Shared numbers, layouts and protocol values. |
| `Reix` | `ReixABI` | Syscalls, memory/runtime support, IPC, clients and service boot helpers. |
| `ReixFS` | `ReixABI` | Filesystem algorithm over a generic `BlockDevice`. |
| `ProcessServerCore` | `ReixABI` | Bounded ELF planning and supported program profiles. |
| `ShellLanguage` | `ReixABI` | Parsing, values, semantic analysis, completion and editing logic. |
| Userland programs | `Reix`, plus their domain modules | Service loops and applications. |

The freestanding build enables Embedded Swift and supplies assembly/runtime boundaries through the build plugin. See [Package.swift](../../Package.swift) for actual target dependencies.

## SDK blocks

| Block | API / state | What callers need to understand |
| --- | --- | --- |
| [Task wrappers](../../Sources/Reix/RXTask.swift) | `SpawnResult`, `TaskCreation`, `TaskStatus` | Bootstrap spawn differs from controlled application launch. |
| [Memory](../../Sources/Reix/Memory) and [heap](../../Sources/Reix/Heap) | `SharedMemory`, `DmaBuffer`, allocation backend | A local address, capability ownership and physical backing are different resources. |
| [IPC](../../Sources/Reix/IPC) | `ReceivedMessage`, pipes, calls/replies | Blocking behavior, delivery status and grant lifetime. |
| [Service clients](../../Sources/Reix/Services) | Block, filesystem, process, name and console clients | Each server owns its operation protocol. |
| [Terminal surfaces](../../Sources/Reix/TextSurface), [input](../../Sources/Reix/Input), [serial](../../Sources/Reix/Serial) | Shared rings and client state | Producer/consumer roles, notification and presentation ownership. |
| [Profiling](../../Sources/Reix/Profile) and [time](../../Sources/Reix/Time) | Authority-scoped observation and clock wrappers | Units, authority and operation-specific results. |
| Runtime, formatting and memory helpers | Freestanding support functions | Local implementation support, not additional kernel services. |

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
