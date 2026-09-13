```
    ____       _      ____  _____
   / __ \___  (_)_  _/ __ \/ ___/
  / /_/ / _ \/ / |/_/ / / /\__ \
 / _, _/  __/ />  </ /_/ /___/ /
/_/ |_|\___/_/_/|_|\____//____/

  ReixOS 0.2.0 / AArch64 / Embedded Swift
  A microkernel written in Swift, for fun.
```

# ReixOS

ReixOS is an experimental microkernel written in Embedded Swift for ARM64.

It began as a personal challenge: to understand how far I could push Swift on bare metal and whether I could design a readable kernel without automatically falling back on structures inherited from traditional systems.

That challenge grew into a clear thesis: use Protocol-Oriented Programming as the organizing principle of an entire operating system. Not to erase fifty years of history, but to choose deliberately what is worth keeping and what does not need to follow us forever.

ReixOS is not a reimplementation of Unix in Swift. It takes what it finds useful from Unix, L4, Zircon, Plan 9 and capability systems, but it does not treat POSIX or historical compatibility as design constraints.

Today it boots an AArch64 kernel in QEMU, manages physical and virtual memory, runs processes in isolated address spaces, uses synchronous capability-based IPC, and moves the console, input, terminal, bus, disk driver, filesystem and ordinary application loading into userland.

And yes, there is a real disk now. The virtio-blk driver runs in userland, RxFS has a journal and transactions, and every access passes through authority that was handed out explicitly during boot.

## Technical documentation

The README introduces the project. The documentation describes the current implementation, the boundaries between components and the parts that are still designs rather than working code.

- [Documentation index](Docs/README.md)
- [System map](Docs/Architecture/System.md)
- [Kernel](Docs/Kernel/Overview.md)
- [Userland and the Reix SDK](Docs/Userland/Overview.md)
- [Services and flows](Docs/Userland/Services.md)
- [ABI and shared contracts](Docs/ABI/README.md)
- [Syscalls](Docs/Kernel/Syscalls/README.md)
- [Application launch](Docs/Userland/ProcessLaunch.md)
- [Storage and RxFS](Docs/Architecture/Storage.md)
- [Future concurrency](Docs/Concurrency.md), a proposal that is not yet implemented

The source remains definitive. These documents describe this checkout and do not promise ABI stability or performance results that have not been measured.

## Philosophy

### Protocol-oriented architecture

The kernel is composed of blocks that depend on Swift protocols rather than concrete implementations. `Allocator`, `SchedulerInterface`, `IPCInterface`, `FileSystemInterface`, `SerialDriver`, `InterruptController` and `KernelArchitecture` make the dependencies between subsystems explicit.

The point is not to use protocols everywhere. The point is to place a boundary where it lets ReixOS replace a policy, test an algorithm on the host or prevent one layer from knowing details that do not belong to it.

`BlockDevice` is the clearest example. ReixFS operates on the same protocol whether it uses an in-memory disk during tests or communicates with the virtio driver through an IPC client.

### Authority is handed over, not inherited

A process does not implicitly gain the right to access the machine. Init receives the initial capabilities from the kernel and gives each service only what it needs.

The bus can derive MMIO windows and interrupts. The disk driver receives device, IRQ and DMA authority. The filesystem receives the disk endpoint. An application receives only the capabilities allowed by its launch profile.

Rights can narrow during delegation, never widen.

### Typed data instead of invisible conventions

Errors are named cases, IPC messages have shared contracts, and important resources are represented by types that distinguish identity, authority and local memory.

ReixOS does not use a global contract like `errno`. Each operation preserves its own result and its own failure modes.

### The kernel does as little as possible

The kernel keeps the mechanisms that require privilege: memory, scheduling, processes, IPC, capabilities, interrupts and controlled task construction.

Policy lives above that boundary. `SerialServer` owns UART transport, `InputServer` manages input and focus, `VTAdapter` coordinates terminal presentation, `BlockServer` drives the disk, `FileSystemServer` mounts RxFS and `ProcessServer` loads ordinary applications from the filesystem.

The initrd ELF loader remains in the kernel for bootstrap. The ordinary path is separate: `ProcessServer` reads an ELF from `system/programs`, validates it in userland and uses the `task*` syscalls to construct the new process without giving the kernel an RxFS pathname.

### Storage isolation

RxFS uses capability-bounded containers. A client does not receive a global filesystem, but a view with precise rights such as reading, writing, delegation, quota or administration.

Path syntax makes crossings between containers visible. Shared-memory pipes allow data to move without making the two storage spaces visible to each other.

A private namespace assembled from multiple containers remains a separate goal from the containers that already exist.

### A terminal that understands the meaning of input

The shell is not built as an interpreter for anonymous byte streams. Its parser, catalog, completion engine, editor and results use typed structures.

The terminal path is divided by responsibility:

```text
Shell or application
    -> semantic text surface
    -> VTAdapter
    -> ConsoleServer
    -> SerialServer
    -> UART

UART
    -> SerialServer
    -> VTAdapter
    -> InputServer
    -> session that owns focus
```

This separation already exists. The terminal experience and the shell language remain under development.

## Why Swift

Embedded Swift makes it possible to use value types, enums, generics, protocols and typed errors in a freestanding binary, without Foundation or reliance on the full standard library.

With specialization and whole-module optimization, many generic abstractions are resolved statically. This allows subsystems to remain separate without turning every boundary into dynamic dispatch.

Swift does not make bare metal magically safe. MMIO, page tables, CPU contexts and physical addresses still require unsafe operations. ReixOS tries to confine those operations to the parts that genuinely need them.

The same language is also used for build tooling, handler generation and much of the host test suite.

### Trade-offs

- Embedded Swift and its toolchain continue to evolve.
- The project owns its ABI between kernel and userland.
- Raw memory and hardware require explicit checks that the type system cannot invent.
- The freestanding path does not have the conveniences normally taken for granted in a Swift program.
- Assembly and C remain confined to hardware and ABI boundaries where they are necessary.

## What works today

- AArch64 bootstrap from EL2 to EL1, device tree parsing, GICv2, virtual timer and exception handling.
- Physical and virtual memory management, ASIDs, VMAs, lazy mapping, page faults and partial copy-on-write support.
- Preemptive round-robin scheduling, sleep, termination, faults, zombies and process reaping.
- Rendezvous IPC, calls and replies, attenuable capabilities, badges, shared memory and interrupts delivered to userland.
- Separate userland services for serial transport, console output, input, terminal presentation, names, the bus, disk and filesystem.
- A userland virtio-blk driver and RxFS with containers, transactions, journaling, checksums, scrubbing and recovery.
- A `ProcessServer` that loads supported ELF files from disk, constructs suspended tasks, supplies their environment and returns an attenuated job capability.
- A typed shell with modules, multiline editing, semantic completion and structured output.
- Profiling with per-process statistics, a trace ring, sampling and export to Perfetto.
- Host tests and a QEMU matrix covering boot, low-memory configurations, storage, the terminal and systems without a PMU.

Details and limits for each block are available in the [technical documentation](Docs/README.md).

## Current limitations

- The system uses one core. Secondary cores remain parked.
- Native threads and SMP scheduling are not implemented. The current design is described in [Concurrency](Docs/Concurrency.md).
- `spawnProcess` remains as the initrd bootstrap loader. Ordinary applications use the userland path, but there is no general launcher for arbitrary paths yet.
- `ProcessServer` accepts only supported names and profiles, with a defined set of environment capabilities.
- A private filesystem namespace assembled from multiple containers is not implemented yet.
- `exec` and parts of the older `split` model are incomplete.
- Copy-on-write support exists, but does not yet form a complete general model.
- The QEMU platform used by the project has no IOMMU. A driver authorized to perform DMA therefore belongs to the TCB.
- There are no signals or futexes.
- The terminal and shell language continue to evolve.

## Getting started

ReixOS requires a recent Swift toolchain with Embedded Swift support, LLVM/LLD and QEMU for AArch64. The `reix` command plugin builds the kernel and userland, generates assembly handlers, prepares the initrd and starts the virtual machine. The `Makefile` collects the common entry points.

```bash
make clean && make run
```

To run the host suite and QEMU matrix:

```bash
make test
```

Other useful targets include `make host-test`, `make vm-test`, `make smoke`, `make release` and trace export through `reix trace --export`.

## Roadmap

- [x] Isolated processes and context switching
- [x] Single-core preemptive scheduling
- [x] Synchronous IPC and attenuable capabilities
- [x] Interrupts and disk driver in userland
- [x] RxFS with journaling, transactions and containers
- [x] Terminal split into transport, input and presentation
- [x] Controlled disk-backed application loading through `ProcessServer`
- [ ] Private namespace assembled from multiple containers
- [ ] Complete process replacement and reaping semantics
- [ ] Native kernel threads
- [ ] Multicore scheduling
- [ ] Thread waiting primitives
- [ ] Userland M:N runtime

## License

ReixOS is released under the GNU General Public License v3.0. See [LICENSE](LICENSE) for the full text.
