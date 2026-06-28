//
//  PanicFormatter.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Renders a `PanicReport` into a sequence of `kprint` lines.
///
/// Stateless by design so it can be swapped at compile time with
/// alternative formatters (e.g. JSON dump over UART, compact one-line
/// report for embedded targets without enough console real estate).
public protocol PanicFormatter {
    static func format(_ report: PanicReport)
}


/// Default human-readable formatter. Layout designed for a 80-column
/// serial terminal, no ANSI escape, no UTF-8.
public struct DefaultPanicFormatter: PanicFormatter {

    public static func format(_ report: PanicReport) {
        kprint()
        kprint("[PANIC] CPU 0 - Fatal Exception at EL1")
        kprint("------------------------------------------------------")

        formatExceptionHeader(report)
        formatReason          (report)
        formatAddresses       (report)
        formatContext         (report)

        kprint("------------------------------------------------------")

        formatRegisterDump    (report)
        formatCallTrace       (report)

        kprint("------------------------------------------------------")
        kprint("=                SYSTEM HALTED                       =")
        kprint("------------------------------------------------------")
    }


    private static func formatExceptionHeader(_ report: PanicReport) {
        guard let frame     = report.frame,
              let exception = report.exception
        else { return }

        kprint("Trap Type: Exception Class 0x\(hex: exception.rawValue) (ESR: 0x\(hex: frame.esr))")
    }


    private static func formatReason(_ report: PanicReport) {
        guard let reason = report.reason else { return }

        kprint("Reason:    ")
        kprint("\(reason)")
    }


    private static func formatAddresses(_ report: PanicReport) {
        guard let frame = report.frame else { return }

        kprint("Address:   PC [0x\(hex: frame.elr)] | FAR [0x\(hex: frame.far)]")
    }


    private static func formatContext(_ report: PanicReport) {
        guard let frame = report.frame else {
            kprint("Context:   PID: ###### | Core: 0")
            return
        }

        kprint("Context:   PID: ###### | Core: 0 | PSTATE: 0x\(hex: frame.spsr)")
    }


    private static func formatRegisterDump(_ report: PanicReport) {
        guard let frame = report.frame else { return }

        kprint()
        kprint("GPR State:")

        kprint(" x0-x3  : 0x\(hex: frame.x0) - 0x\(hex: frame.x1) - 0x\(hex: frame.x2) - 0x\(hex: frame.x3)")
        kprint(" x4-x7  : 0x\(hex: frame.x4) - 0x\(hex: frame.x5) - 0x\(hex: frame.x6) - 0x\(hex: frame.x7)")
        kprint(" x8-x11 : 0x\(hex: frame.x8) - 0x\(hex: frame.x9) - 0x\(hex: frame.x10) - 0x\(hex: frame.x11)")
        kprint(" x12-x15: 0x\(hex: frame.x12) - 0x\(hex: frame.x13) - 0x\(hex: frame.x14) - 0x\(hex: frame.x15)")
        kprint(" x16-x19: 0x\(hex: frame.x16) - 0x\(hex: frame.x17) - 0x\(hex: frame.x18) - 0x\(hex: frame.x19)")
        kprint(" x20-x23: 0x\(hex: frame.x20) - 0x\(hex: frame.x21) - 0x\(hex: frame.x22) - 0x\(hex: frame.x23)")
        kprint(" x24-x27: 0x\(hex: frame.x24) - 0x\(hex: frame.x25) - 0x\(hex: frame.x26) - 0x\(hex: frame.x27)")
        kprint(" x28-x29: 0x\(hex: frame.x28) - 0x\(hex: frame.x29)")
        kprint(" lr(x30): 0x\(hex: frame.x30)")
    }


    private static func formatCallTrace(_ report: PanicReport) {
        guard let frame = report.frame else { return }

        kprint()
        kprint("Call Trace:")
        kprint("  [<0x\(hex: frame.elr)>] (PC/ELR)")
        kprint("  [<0x\(hex: frame.x30)>] (LR/x30)")

        Arch.CPU.printStackTrace(frame.x29)
    }
}
