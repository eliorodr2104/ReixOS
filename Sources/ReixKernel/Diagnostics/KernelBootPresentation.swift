//
//  KernelBootPresentation.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 13/09/2026.
//

import ReixABI

/// Everything the kernel says about its own bring-up, decided in one place.
///
/// The subsystems announce themselves exactly as they always did. What this
/// changes is where those lines go: outside `diagnostic` the sink records them
/// and prints nothing, so a panic still quotes the whole boot while the console
/// shows only what the mode asked for.
///
/// The three contracts, in full:
///
///   * `standard`   one line, the banner, before user space starts.
///   * `verbose`    the banner, then the three macro phases the kernel owns.
///                  Init owns the other two, so nothing here duplicates them.
///   * `diagnostic` the banner with its copyright line, then every subsystem.
///
/// The eleven `TraceBootPhase` records are unaffected by all of it: they are
/// filed by `Kernel.bootPhase` whatever the mode is, which is why the boot
/// timeline survives a boot that printed a single line.
enum KernelBootPresentation: Loggable {

    static let nameLog : StaticString = "[KERN]"
    static let logLevel: LogLevel     = .boot


    /// Prints the banner and puts the sink into the mode the rest of the boot
    /// runs under. Called before the first subsystem is constructed.
    static func begin() {
        // The guest shares a terminal with whatever launched it, and lands in
        // the middle of that output without this.
        kprint()

        // One record, so the whole line is in the ring. Streaming the version
        // through `kputc` put those bytes on the wire and nowhere else.
        kprint("[ reix ] ReixOS \(ReixVersion.major).\(ReixVersion.minor).\(ReixVersion.patch) / AArch64 / Embedded Swift")

        guard BootMode.current != .diagnostic else {
            kprint("[ reix ] (c) 2026 Eliomar Alejandro Rodriguez Ferrer - GPLv3")
            return
        }

        LogSink.mode = .recordOnly
    }


    /// One bring-up milestone, from `Kernel.bootPhase`.
    ///
    /// Three of the eleven phases close a macro phase, and those three are the
    /// kernel's whole share of a verbose boot. The rest are trace records and
    /// ring history, which is what they were before this existed.
    static func phase(_ phase: UInt16) {
        guard BootMode.current == .verbose else { return }

        switch phase {
            case TraceBootPhase.heapReady: announce(.memory)
            case TraceBootPhase.fsReady  : announce(.devices)
            case TraceBootPhase.timerOn  : announce(.processes)
            default                      : break
        }
    }


    /// The last sink decision the kernel makes.
    ///
    /// From here the timer tick drains the ring and no kernel line still has to
    /// beat user space to the wire, so nothing is written through any more.
    static func handOver() {
        LogSink.mode = .deferred
    }


    /// Prints one line through a sink that is otherwise only recording, and
    /// puts it back. The milestones are the only output a verbose boot gets.
    private static func announce(_ milestone: BootMilestone) {
        let recording = LogSink.mode
        LogSink.mode  = .synchronous

        Self.boot("\(milestone.label)")

        LogSink.mode = recording
    }
}
