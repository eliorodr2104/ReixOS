# ReixOS

ReixOS is an experimental, highly modular microkernel written in Embedded Swift for the ARM64 (AArch64) architecture. 

It started as a personal challenge and a style exercise to push the limits of my Swift knowledge, but it is driven by a specific design philosophy: **bringing Protocol-Oriented Programming (POP) to the bare metal to fix the historical flaws of traditional operating systems.**

## The Philosophy

ReixOS is built around a few core radical ideas:

* **Protocol-Oriented Architecture:** The kernel is strictly modular and based on Swift Protocols. Components are completely decoupled. For example, you can swap out the Allocator without ever touching the Physical Page Manager (PPM) for example.
* **Human-Readable Systems:** Traditional OS design (like Linux) relies on cryptic syscalls and hard-to-read integer error codes. ReixOS aims to expose everything through high-level, human-readable data structures and clear errors. 
* **The Anti-Bash Terminal:** In the future, the terminal will not rely on parsing endless, unstructured strings with indecipherable commands. Instead, it will be built on POP: every terminal module will adhere to strict protocols, exchanging strongly-typed data instead of raw text.
* **Absolute Isolation:** A pure microkernel approach where every process is completely isolated, not just in its virtual address space, but eventually at the disk/storage level as well.

## Architecture & Current State

The project is currently in an **embryonic state**. The codebase is primarily Swift (~75%), falling back to C and Assembly only when strictly necessary for low-level CPU bootstrapping and ABI requirements.

At this stage, the foundational subsystems are in place:
* Basic UART Driver
* Physical Page Management (PPM)
* Virtual Memory Management (VMM)
* Exception Vector Table (EVT)
* Basic Kernel Heap

## Getting Started

To build and run ReixOS, you don't need a complex custom toolchain. You just need a recent **Swift Toolchain with Embedded Swift support**. 

The Makefile takes care of compiling the source and launching it inside QEMU. Simply run:

```bash
clear && make clean && make run
```

## Roadmap

The next major milestones for ReixOS involve transitioning from hardware initialization to a fully working user-space:

- [ ] Processes and Context Switching
- [ ] CPU Scheduler
- [ ] Functional User-Space execution
- [ ] Robust Heap allocation for all processes
- [ ] Inter-Process Communication (IPC)
- [ ] Better I/O handling
- [ ] POP-based Shell implementation

## License

This software is released under the GNU License.
