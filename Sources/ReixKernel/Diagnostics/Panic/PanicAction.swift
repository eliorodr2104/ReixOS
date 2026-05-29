//
//  PanicAction.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Terminal step of the panic flow.
///
/// Invoked right after the formatter has finished printing the report.
/// `execute()` must never return — it is the kernel's last instruction
/// path. Alternative actions (reboot, core dump, kernel debugger entry)
/// can implement the protocol without touching the formatter.
public protocol PanicAction {
    static func execute() -> Never
}


/// Disables interrupts and parks the CPU in WFI forever. The standard
/// post-panic action: deterministic, no further state mutation.
public struct HaltPanicAction: PanicAction {

    public static func execute() -> Never {
        Arch.CPU.disableInterrupts()

        while true { Arch.CPU.waitForInterrupt() }
    }
}
