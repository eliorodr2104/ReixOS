# ReixOS documentation

A guide to the implemented kernel, its userland boundary and the services around it. Pages follow subsystem responsibilities and cross-component behavior. API tables cover the contracts useful for understanding or using a block; straightforward helpers remain in the linked source.

## Start here

- [Kernel overview](Kernel/Overview.md): responsibilities, execution model and source boundaries.
- [System map](Architecture/System.md): the microkernel, userland, RAM and disk in one diagram.
- [RAM layout](Architecture/Memory.md): physical reservations, kernel mapping and user virtual addresses.
- [Disk layout](Architecture/Storage.md): RxFS geometry, records and journal ordering.

## Kernel

| Block | Read this to understand |
| --- | --- |
| [Boot](Kernel/Boot.md) | How managers, memory and `Init` are established. |
| [Memory](Kernel/Memory.md) | Physical ownership, virtual regions, faults and kernel allocations. |
| [Processes](Kernel/Processes.md) | Lifetime, address spaces, suspended configuration and job control. |
| [Scheduling](Kernel/Scheduling.md) | Runnable queues, deadlines, exception-return switching and long operations. |
| [IPC and capabilities](Kernel/IPC.md) | Authority, message delivery, blocking and object references. |
| [Interrupts](Kernel/Interrupts.md) | GIC routing, user-owned IRQs and the driver boundary. |
| [Syscalls](Kernel/Syscalls/README.md) | All current operations, grouped by purpose, with raw inputs and results. |

## ABI and userland

| Area | Read this to understand |
| --- | --- |
| [ABI boundaries](ABI/README.md) | Shared definitions versus register, service and disk contracts. |
| [IPC encoding](ABI/IPC.md) | Message registers, statuses, grants and receiver ownership. |
| [Service protocols](ABI/Services.md) | Launch, storage, terminal and discovery contracts. |
| [Userland and SDK](Userland/Overview.md) | Build layers, wrappers, runtime support and capability-bearing values. |
| [Services](Userland/Services.md) | Which process owns each responsibility and how requests flow. |
| [Application launch](Userland/ProcessLaunch.md) | ELF planning, task construction, environment handoff and supervision. |
| [Storage](Userland/Storage.md) | Device queue, mounted-volume ownership and filesystem clients. |

## Future designs

[Concurrency](Concurrency.md) is a proposal for native 1:1 threads and a separate userland M:N runtime. Its proposed TCB, threading and `rxTask` interfaces are not presented as current implementation.

## Keeping the docs useful

Document a block when its ownership, lifecycle, failure behavior or interaction with another block needs explanation. Add a dedicated interface reference when callers need a precise contract. Avoid repeating every source file, obvious enum case or trivial forwarding function.

The linked source is the implementation reference. Numeric limits and signatures describe this checkout; these pages establish neither a stable ABI nor new runtime/performance evidence.
