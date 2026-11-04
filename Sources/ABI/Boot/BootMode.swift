//
//  BootMode.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 13/09/2026.
//

/// How much of its own bring-up this machine says out loud.
///
/// One value for the whole image. The kernel and every userland program are
/// compiled from the same `BOOT_MODE`, so there is no runtime knob to read,
/// nothing to hand between processes, and a line the mode does not want costs
/// no instructions and no string bytes.
///
/// Presentation only, and deliberately so: no mode turns on a self-test, fault
/// injection or profiling the other two do not have. Those live behind their
/// own defines (`REIX_RUNTIME_DIAGNOSTIC` and its neighbours) and are not
/// wired to this one.
public enum BootMode: UInt8 {

    /// The banner, then the shell. What `make run` boots.
    case standard = 0

    /// The five `BootMilestone` lines, and nothing else.
    case verbose = 1

    /// One line per subsystem, kernel and userland. What the smoke tests and
    /// the QEMU matrix boot, because their markers are those lines.
    case diagnostic = 2

    #if REIX_BOOT_DIAGNOSTIC
    public static let current: BootMode = .diagnostic
    #elseif REIX_BOOT_VERBOSE
    public static let current: BootMode = .verbose
    #else
    public static let current: BootMode = .standard
    #endif
}


/// The five lines a `verbose` boot prints, in the order they happen.
///
/// The kernel owns the first three and init the last two, so every phase is
/// announced exactly once: no server repeats the macro phase it belongs to.
public enum BootMilestone: UInt8 {
    case memory    = 0
    case devices   = 1
    case processes = 2
    case userland  = 3
    case session   = 4

    public var label: StaticString {
        switch self {
            case .memory   : "memory online"
            case .devices  : "devices online"
            case .processes: "processes online"
            case .userland : "userland started"
            case .session  : "session ready"
        }
    }
}
