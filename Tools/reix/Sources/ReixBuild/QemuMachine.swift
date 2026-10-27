//
//  QemuMachine.swift
//  ReixOS
//

import Foundation

/// The machine this kernel boots on, defined once.
///
/// It was defined four times: the Makefile's QEMU_FLAGS, scripts/smoke.sh, the
/// plugin's run command and the Xcode scheme, with a comment in each asking the
/// next reader to keep them in step. This is the copy that survives the plugin;
/// the other three go when a later phase retires the scripts that carry them.
///
/// `pmu=on` gives the guest a PMUv3 block, which the kernel enables at boot and
/// which both the trace's pmuSection records and userland's PMUSection read.
public enum QemuMachine {

    /// `mem` empty means the machine default, `disk` nil means no virtio-blk
    /// transport at all, and `initrd` nil means the guest falls back to the
    /// copy linked into kernel.bin, which is the only way 4 MiB boots.
    public static func arguments(
        mem   : String?,
        disk  : URL?,
        kernel: URL,
        initrd: URL?
    ) -> [String] {
        var arguments = [
            "-machine", "virt,gic-version=2",
            "-cpu", "cortex-a53,pmu=on",
            "-nographic",
        ]
        if let mem, !mem.isEmpty { arguments += ["-m", mem] }
        if let disk {
            arguments += [
                "-drive", "file=\(disk.path),if=none,format=raw,id=reixdisk",
                "-device", "virtio-blk-device,drive=reixdisk",
            ]
        }
        arguments += ["-kernel", kernel.path]
        if let initrd { arguments += ["-initrd", initrd.path] }
        return arguments
    }


    /// The other half of handing the terminal over: the Makefile's
    /// `trap '…' EXIT HUP INT TERM`, which a Swift `defer` is not.
    ///
    /// A closed window sends SIGHUP and a `kill` sends SIGTERM. Neither unwinds
    /// the stack, so without this the marker outlives the guest that owned it
    /// and the next boot refuses to start, on a terminal still in bracketed
    /// paste. Re-raised with the default disposition afterwards, so the exit
    /// status still says which signal ended it.
    public static func releaseOnSignal(marker: String) {
        liveMarker = strdup(marker)

        for number in [SIGHUP, SIGINT, SIGTERM] { signal(number, restore) }
    }


    /// Waits for a spawned guest that owns the terminal, and takes it back.
    ///
    /// Foundation spawns with `POSIX_SPAWN_SETPGROUP` and pgroup 0, so the child
    /// leads a new process group that is not the terminal's foreground one. QEMU
    /// with `-nographic` drives the terminal, and both `tcsetattr` and a read
    /// from a background group stop the caller (SIGTTOU, SIGTTIN). Measured: the
    /// guest sat in state `T` forever, printing nothing and seeing no key, so
    /// Ctrl-A X could not reach it. The Makefile's shell recipe never hit this
    /// because job control put QEMU in the foreground group for free.
    ///
    /// Rejected: respawning this one process with `posix_spawn`. It would spell
    /// the group out rather than infer it, and buy nothing, since the child can
    /// still reach the terminal before the parent's `tcsetpgrp` either way.
    public static func waitInForeground(_ guest: Process) {
        guard isatty(STDIN_FILENO) == 1 else { return guest.waitUntilExit() }

        let ours   = getpgrp()
        let theirs = guest.processIdentifier

        // `tcsetpgrp` from outside the foreground group raises SIGTTOU on the
        // caller, which is precisely what the second call below would do.
        let previous = signal(SIGTTOU, SIG_IGN)
        tcsetpgrp(STDIN_FILENO, theirs)

        // A child that touched the terminal first is already stopped, and going
        // foreground does not resume it. Nothing to do if it never stopped.
        killpg(theirs, SIGCONT)

        guest.waitUntilExit()

        tcsetpgrp(STDIN_FILENO, ours)
        signal(SIGTTOU, previous)
    }
}

/// Async-signal-safe, which is the whole constraint: `unlink`, `write`, `signal`
/// and `raise` are on the permitted list and nothing else here is. The marker is
/// a C string and the sequence lives in the binary, so neither read allocates.
private func restore(_ number: Int32) {
    if let liveMarker { unlink(liveMarker) }
    _ = write(1, restoreSequence.utf8Start, restoreSequence.utf8CodeUnitCount)

    signal(number, SIG_DFL)
    raise(number)
}

nonisolated(unsafe) private var liveMarker: UnsafeMutablePointer<CChar>?

/// Puts the terminal back when the guest ends, however it ends.
///
/// The guest parks its cursor just after `reix❯ ` and turns on bracketed paste
/// and the keyboard protocol, and turns neither off: Ctrl-A X gives it no chance
/// to. The next build then draws around a row nobody owns any more, which is
/// where the stray prompt in the middle of somebody's build output came from.
///
/// Erase to the end of the *screen*, not the end of the line. Everything above
/// the cursor is the boot log and is history worth keeping; everything at or
/// below it is screen the guest drew and nobody owns any more. Then the two
/// modes off. A terminal that knows neither ignores both.
private let restoreSequence: StaticString = "\r\u{1B}[J\u{1B}[?2004l\u{1B}[<u"

