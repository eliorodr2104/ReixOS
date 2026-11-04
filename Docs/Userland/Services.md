# Services and applications

[Documentation home](../README.md) · [Userland overview](Overview.md) · [Service protocols](../ABI/Services.md)

`Init` assembles the system by launching services and granting the authority each one needs. Endpoints are passed explicitly; NameServer is available for named publication, but not every service is registered there.

## Service responsibilities

| Component | What it does | Authority / state that matters |
| --- | --- | --- |
| [Init](../../Sources/Userland/System/Init) | Boots services, distributes capabilities and coordinates the session. | Initial device, spawn, clock, profiler and storage authority. |
| [SerialServer](../../Sources/Userland/System/SerialServer) | Operates the UART byte transport and shared serial rings. | UART mapping, IRQ set, reader/writer sessions. |
| [ConsoleServer](../../Sources/Userland/System/ConsoleServer) | Provides output transport through the serial writer. | Serial-writer capability and per-client output state. |
| [InputServer](../../Sources/Userland/System/InputServer) | Routes input events and maintains focus/session ownership. | Source, consumer and focus roles. |
| [VTAdapter](../../Sources/Userland/OS/Terminal/VTAdapter) | Connects semantic text surfaces to terminal byte output and serial input. | Console transport, serial reader and input-source capability. |
| [NameServer](../../Sources/Userland/System/NameServer) | Publishes and resolves named endpoints. | Registry state and registration/lookup authority. |
| [VirtioBus](../../Sources/Userland/Drivers/VirtioBus) | Walks authorized virtio-MMIO transports and starts the block driver. | Bus authority; derived device and IRQ capabilities. |
| [BlockServer](../../Sources/Userland/Drivers/VirtioBlock) | Runs the virtio-block driver and serves queued sector I/O. | Device/IRQ/DMA authority, four request slots, volume owner. |
| [FileSystemServer](../../Sources/Userland/System/FileSystemServer) | Mounts RxFS and serves object/container operations. | Disk endpoint, filesystem state, client sessions and scoped rights. |
| [ProcessServer](../../Sources/Userland/System/ProcessServer) | Loads supported applications from the programs directory and supervises jobs. | Programs directory, task creation, selected environment grants, four pending launches and eight total launch/job reservations. |

## Terminal flow

```mermaid
flowchart LR
    APP[Shell / application] -->|semantic text| VT[VTAdapter]
    VT -->|output bytes| CON[ConsoleServer]
    CON -->|shared serial output| SER[SerialServer]
    SER <--> UART[PL011 UART]
    SER -->|input bytes| VT
    VT -->|input events| INPUT[InputServer]
    INPUT -->|focused session| APP
```

The adapter coordinates terminal presentation. InputServer owns input routing/focus. SerialServer owns byte transport. Kernel boot/panic output remains a separate low-level path to the UART.

## Storage and launch flow

```mermaid
flowchart LR
    APP[Application] --> FS[FileSystemServer]
    PS[ProcessServer] -->|read ELF| FS
    FS -->|sector I/O| BLK[BlockServer]
    BLK --> DISK[(Virtio disk)]
    PS -->|task syscalls| K[Kernel]
```

Init gives FileSystemServer the disk endpoint and passes scoped filesystem capabilities upward. The programs namespace is rooted at `system/programs`. Missing storage or program-directory authority can prevent ordinary application launch without changing the kernel's initrd bootstrap path.

## Applications and reusable logic

| Component | Role |
| --- | --- |
| [Shell](../../Sources/Userland/OS/Terminal/Shell) | Interactive command execution, pipelines, sessions and rendering. |
| [ShellLanguage](../../Sources/Userland/OS/Terminal/ShellLanguage) | Shared parsing, typed values, analysis, catalog and completion. |
| [LineEditor](../../Sources/Userland/OS/Terminal/LineEditor) | Editor state, key mapping, panels and editor presentation. |
| [Top](../../Sources/Userland/OS/Apps/Top) | Consumes process/system statistics and trace export for display. |
| [StorageCheck](../../Tests/Guest/StorageCheck) | Dedicated storage exercise/diagnostic program. |
| [ReixFS](../../Sources/Libraries/FS) | On-disk filesystem implementation used by FileSystemServer. |
| [SerialServerCore](../../Sources/Userland/System/SerialServerCore) / [InputServerCore](../../Sources/Userland/System/InputServerCore) | Serial and input implementation beside the services that own it. |
| [TerminalCore](../../Sources/Userland/OS/Terminal/TerminalCore) | Screen model, palette, VT conversion and terminal transport/session logic. |
| [ProcessServerCore](../../Sources/Userland/System/ProcessServerCore) | ELF validation, page-sized copying, program profiles and the generic launch supervisor. |

ProcessServer advances launch records under a single five-second deadline, keeps the file claim through the last copy and answers the original caller only after readiness. It sweeps abandoned launches and exited jobs even without a new request; the kernel remains responsible for process teardown. [Launch supervision](ProcessLaunch.md#resumable-launch-and-cleanup) describes the limits and cleanup policy.

The Shell's internal parser/editor helpers are linked as a block: their existence does not add another kernel component. See [Process launch](ProcessLaunch.md) and [Storage](Storage.md) for the cross-component contracts.
