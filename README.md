```
    ____       _      ____  _____
   / __ \___  (_)_  _/ __ \/ ___/
  / /_/ / _ \/ / |/_/ / / /\__ \
 / _, _/  __/ />  </ /_/ /___/ /
/_/ |_|\___/_/_/|_|\____//____/

  ReixOS 0.1.5 — AArch64 / Embedded Swift
  A microkernel written in Swift, for fun.
```

# ReixOS

ReixOS is an experimental microkernel written in **Embedded Swift** for the **ARM64 (AArch64)** architecture.

It began as a personal challenge, a style exercise to push the limits of my Swift knowledge... but it has grown into something with a clear thesis behind it: **bringing Protocol-Oriented Programming (POP) to the bare metal to fix the historical flaws of traditional operating systems.**

Despite its experimental, single-author nature, ReixOS is no longer a toy. It already boots on QEMU, brings up its own physical and virtual memory managers, schedules processes with real context switches, loads ELF binaries into isolated address spaces, and lets those processes talk to each other through a synchronous, capability-based IPC mechanism. It is small, it is honest about what it can't yet do, but it *runs*.

---

## The Philosophy

ReixOS is built around a few core, deliberately radical ideas. Each one is a reaction to something I find frustrating about the way traditional operating systems are built.

* **Protocol-Oriented Architecture.** The kernel is strictly modular and built on Swift protocols. Components are decoupled behind interfaces `Allocator`, `SchedulerInterface`, `IPCInterface`, `FileSystemInterface`, `SerialDriver`, `InterruptController`, and more. You can swap the Buddy allocator for a different one without ever touching the Physical Page Manager, because the PPM only knows the `Allocator` protocol, not its implementation. The kernel is composed of replaceable parts, not a monolith of intertwined globals.

* **Human-Readable Systems.** Traditional OS design (Linux included) leans on cryptic syscalls and inscrutable integer error codes. ReixOS exposes everything through high-level, strongly-typed data structures and explicit, named errors. There is no `errno`. A function that can fail says exactly *how* it can fail, in the type system: `PPMError.protectedMemoryViolation`, `IPCError.notEnoughRights`, `FSError.readOnlyFileSystem`. The error *is* the documentation.

* **The Anti-Bash Terminal.** In the future, the shell will not parse endless streams of unstructured text and indecipherable flags. It will be built on POP: every terminal module will conform to strict protocols and exchange strongly-typed data instead of raw strings. A pipeline becomes a chain of typed transformations, not a guessing game about what `$1` happened to contain.

* **Absolute Isolation.** A pure microkernel approach where every process is fully isolated not only in its virtual address space, but down at the storage level as well. Every process is its own **container** with its own private filesystem. A central FS manager unifies these private filesystems into one global namespace, and paths make the boundaries explicit: in `/reix::terminal/folder`, `reix` is the device's root container, `::` marks a crossing *into* another container (here, `terminal`), and the slashes navigate folders inside it. You always know when a path leaves your own container and enters someone else's.

* **The Kernel Does As Little As Possible.** Everything that *can* be a userland process eventually *will* be one, talking to the rest of the system over IPC. Today some services still live inside the kernel for bootstrapping convenience (process spawning, and a future name server), exposed through syscalls but these are deliberately **temporary**. As the microkernel matures, they migrate out into dedicated userland servers (a **Process Server**, a **Name Server**), and the corresponding syscalls collapse into thin IPC calls to those servers.

* **Flat Process Tree.** Child processes are terminal: they cannot fork or spawn children of their own. The hierarchy is strictly one level deep (Parent → Children). This kills entire classes of complexity and security problems that come from deep, mutable process trees, and it makes the lifecycle of every process easy to reason about.

---

## Influences

ReixOS is not built in a vacuum, and it doesn't pretend to be. It borrows freely:

* **From Unix:** the familiar, pragmatic primitives `brk`/`sbrk`/`mmap` for memory, path-based files, exit codes, a parent→child process model. The things Unix got right and that programmers already understand.
* **From Fuchsia (Zircon) and the L4 family:** the microkernel discipline a minimal kernel, **capabilities** instead of ambient authority, **synchronous IPC** (L4-style rendezvous) as the fundamental communication primitive, and services pushed out into userland servers.

But ReixOS isn't a clone of any of them. The goal is a single, coherent philosophy of its own: **Protocol-Oriented Programming as the organizing principle of the whole system**, strongly-typed data instead of stringly-typed interfaces, and human-readable structures end to end. Where Unix and L4 disagree, ReixOS picks whichever fits *that* vision and where neither fits, it does its own thing.

---

## Why Swift?

Writing a kernel in Swift sounds unusual, and that's part of the point. But it isn't a gimmick — there are concrete reasons, and the codebase leans on every one of them.

**Embedded Swift means no hidden machinery.** ReixOS uses Swift's *Embedded* mode (`-enable-experimental-feature Embedded`). Swift has no garbage collector it never did and here there is **no ARC (Automatic Reference Counting) either**: the entire kernel is built from value types (structs and enums) with zero reference-counted classes, so there is no retain/release traffic and no implicit memory management running underneath you. No heavy runtime, no reflection metadata, no allocations behind your back. The compiler emits tight, freestanding code that links into a bare-metal binary the same way C would but with a far stronger type system on top.

**Protocols give polymorphism without a vtable tax.** With whole-module optimization and generics specialized at compile time, a `PhysicalPageManager<A: Allocator>` resolves its allocator calls statically. You get clean, swappable abstractions *and* the performance of direct calls. POP is what lets the kernel be modular without paying for it at runtime.

**Value types and explicit ownership over raw pointers.** Structs, enums with associated values, and Swift's ownership model let the kernel model hardware and state precisely page table entries, trap frames, VMA nodes with far fewer of the foot-guns that come from hand-rolled C pointer arithmetic. Where raw memory access is genuinely needed, it's confined and explicit rather than pervasive.

**Typed error handling instead of error codes.** Swift's typed `throws(SomeError)` lets every fallible kernel path declare its exact failure modes in the signature. This is the technical backbone of the "human-readable systems" philosophy: a missing capability, a protected-page violation, or an out-of-frames condition is a named case, checked by the compiler, not a magic `-1` you have to look up.

**Memory safety where the metal allows it.** You can't make a kernel fully safe — someone has to poke physical addresses. But Swift lets the *vast majority* of the kernel stay in safe territory, shrinking the unsafe surface down to a handful of clearly-marked bridges to assembly and MMIO.

### The trade-offs (an honest section)

Swift on bare metal is not free, and pretending otherwise would be dishonest:

* **No standard library.** Embedded Swift gives you the language, not Foundation or the full stdlib. Anything you'd normally import, you build.
* **A few C and assembly stubs are unavoidable.** CPU bootstrap, exception vectors, context switching, and MMIO ABI live in `.S` and `.c` files Swift sits on top of them, it doesn't replace them.
* **The toolchain is experimental.** Embedded Swift is still gated behind experimental feature flags and evolves release to release.
* **You own the ABI.** Syscall calling conventions, linker layout, and the kernel/userland boundary are all hand-defined. The compiler won't do it for you.

The bet ReixOS makes is that these costs are worth paying for a kernel that is dramatically easier to read, refactor, and reason about than its C equivalent.

---

## Architecture Overview

The codebase is overwhelmingly Swift, dropping to C and assembly only for low-level CPU bootstrapping and ABI requirements. It's organized in layers, each exposing a protocol that the layer above depends on:

```
Sources/ReixKernel/
├── Arch/aarch64/        # Boot (boot.S), MMU, CPU, exception vectors, context switch
├── Memory/
│   ├── Physical/        # PhysicalPageManager + per-frame refcounting
│   ├── Allocators/      # BuddyAllocator (order-based, intrusive free lists)
│   ├── Virtual/         # VirtualMemoryManager: TTBR0/TTBR1, ASIDs, 48-bit VA
│   └── Heap/            # BucketsHeap: power-of-two slab allocator
├── Process/             # Process, ProcessManager, VMAManager, hot/cold metadata
├── Scheduler/           # RoundRobin scheduler, queues
├── InterProcessControl/ # RendezvousIPC, capabilities, endpoints
├── Syscall/             # RXTask / RXMemory / RXIPC / RXIO
├── FileSystem/Tar/      # Read-only TAR filesystem from the initrd
├── Drivers/             # PL011 UART, GICv2 interrupt controller
├── Platform/ELFParser/  # ELF64 PT_LOAD loader
└── Diagnostics/         # Subsystem-tagged kernel logging

Sources/Userland/        # Init, Child, ServerProcess + the Reix syscall module
```

The key protocols that hold this together `Allocator`, `KernelHeapInterface`, `SchedulerInterface`, `IPCInterface`, `FileSystemInterface`, `VMAStructure`, `SerialDriver`, `InterruptController`, `KernelArchitecture` are what make each box above independently understandable and replaceable.

---

## What's Implemented

The foundational subsystems are in place and working:

**Boot & Architecture**
* AArch64 bootstrap: EL2→EL1 drop, secondary-core parking, BSS zeroing, exception-vector (VBAR_EL1) install, FP enable, virtual timer setup.

**Memory**
* **Physical Page Manager** with per-frame metadata and reference counting.
* **Buddy allocator** with order-based intrusive free lists (4 KiB pages, up to order 11).
* **Virtual Memory Manager** with separate kernel/user root tables (TTBR1/TTBR0), 16-bit ASIDs, and a 48-bit virtual address space.
* **VMA tracking** with adjacent-region coalescing, lazy mapping (PTEs filled on first page fault), and a downward-growing user stack.
* **Bucket/slab kernel heap** carved from the PPM, returning pages when fully freed.

**Processes & Scheduling**
* Round-robin scheduler with real time-slice preemption (quantum-based) and ready/waiting/terminated queues.
* Full process model with hot/cold field separation, flat parent→child relationships, and real context switching.
* ELF64 loader mapping `PT_LOAD` segments page-by-page into isolated address spaces.
* Functional user-space execution from binaries packed in the initrd.

**System Calls (~22)**
* **Task:** `exit`, `yield`, `getPID`, `getParentPID`, `parentEndpoint`, `spawnProcess`, `split`.
* **Memory:** `brk`, `sbrk`, `mmap`, `munmap`.
* **IPC:** `send`, `receive`, `receiveTimeout`, `call`, `reply`, `replyRecv`, `trySend`, `tryReceive`.
* **I/O:** `putchar`.

> **Note:** some of these syscalls are scaffolding, not the final design. Services like process spawning (and an upcoming name server) currently live in the kernel to get the system off the ground; following the microkernel approach properly, they will move into userland servers and these syscalls will become thin IPC calls to them.

**IPC**
* Synchronous **rendezvous** message passing: senders block until a receiver is ready and vice-versa.
* **Capability transfer** — a sender can grant a capability handle across an endpoint.
* Parent endpoint seeded at spawn and recoverable via the `parentEndpoint()` syscall.

**Filesystem & Drivers**
* Read-only **TAR filesystem** parsed from the initrd, with `open`/`close`/`read`/`seek`/`getInfo`.
* **PL011 UART** serial driver and **GICv2** interrupt controller with a virtual-timer handler.

**Cross-cutting**
* Fully **typed, enum-based error handling** across every subsystem no `errno`.
* Subsystem-tagged kernel logging (`[PPM]`, `[VMM]`, `[IPC]`, …).

---

## What's Missing / Known Limitations

In the spirit of being honest about the state of things:

* **Servers still live in the kernel the headline gap.** A true microkernel keeps services in userland; ReixOS currently keeps a few (process spawning, the future **Name Server** and **Process Server**) inside the kernel, reached through temporary syscalls. Moving these out into dedicated userland servers is the single most important architectural step still ahead, and the rest of the design is built to make it possible.
* **Per-container filesystem isolation** is a design goal, not a reality yet. Today there is a single read-only TAR filesystem; the per-process containerized FS unified under one namespace (the `/reix::container/...` model above) is not implemented.
* **Userland `malloc`/`free`** are still stubs (`user_stubs.c`); the real user heap on top of `brk`/`mmap` isn't wired yet.
* **The filesystem is read-only** — `write()` is not implemented.
* **`exec`, `fork`/`split`, and child reaping** exist as syscalls but are incomplete.
* **Copy-on-write** infrastructure is partly present but not fully connected.
* **Single-core only.** Secondary cores are parked; there's no SMP scheduling yet.
* **No signals**, and no IPC abstractions beyond rendezvous (no futexes).
* **Device-tree parsing** is minimal.

---

## Getting Started

You don't need a complex custom toolchain just a recent **Swift toolchain with Embedded Swift support** (developed against Swift 6.3.x), plus LLVM/LLD and QEMU for AArch64. The `Makefile` handles compiling the kernel, building the userland ELFs, packing the initrd, and launching everything under QEMU.

```bash
make clean && make run
```

This boots `kernel.bin` on `qemu-system-aarch64` (machine `virt`, `cortex-a53`, GICv2) with the initrd attached. You'll see the boot banner, each subsystem coming up with its tagged log line, and the `Init` process starting and spawning its children over IPC all on the serial console.

---

## Roadmap

The next milestones move ReixOS from "boots and runs user-space" toward a genuinely usable system:

- [x] Processes and context switching
- [x] CPU scheduler
- [x] Functional user-space execution
- [x] Robust heap allocation in the kernel
- [x] Inter-process communication (rendezvous + capabilities)
- [ ] **Move core services out of the kernel into userland (Process Server, Name Server)** — the main microkernel milestone
- [ ] Per-container filesystems unified under one namespace (`/reix::container/...`)
- [ ] Real userland heap (`malloc`/`free` on top of `brk`/`mmap`)
- [ ] Complete `exec` and child reaping
- [ ] Writable filesystem
- [ ] Better I/O handling
- [ ] POP-based shell implementation
- [ ] Multicore (SMP) scheduling

---

## License

ReixOS is released under the **GNU General Public License v3.0**. See [LICENSE](LICENSE) for the full text.
