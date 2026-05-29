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

        kprintf(
            "Trap Type: Exception Class 0x%x (ESR: 0x%x)\n",
            exception.rawValue,
            frame.esr
        )
    }


    private static func formatReason(_ report: PanicReport) {
        guard let reason = report.reason else { return }

        kprint("Reason:    ")
        kprint(reason)
    }


    private static func formatAddresses(_ report: PanicReport) {
        guard let frame = report.frame else { return }

        kprintf(
            "Address:   PC [0x%x] | FAR [0x%x]\n",
            frame.elr,
            frame.far
        )
    }


    private static func formatContext(_ report: PanicReport) {
        guard let frame = report.frame else {
            kprint("Context:   PID: ###### | Core: 0")
            return
        }

        kprintf(
            "Context:   PID: ###### | Core: 0 | PSTATE: 0x%x\n",
            frame.spsr
        )
    }


    private static func formatRegisterDump(_ report: PanicReport) {
        guard let frame = report.frame else { return }

        kprint()
        kprint("GPR State:")

        kprintf(" x0-x3  : 0x%x - 0x%x - 0x%x - 0x%x\n", frame.x0, frame.x1, frame.x2, frame.x3)
        kprintf(" x4-x7  : 0x%x - 0x%x - 0x%x - 0x%x\n", frame.x4, frame.x5, frame.x6, frame.x7)
        kprintf(" x8-x11 : 0x%x - 0x%x - 0x%x - 0x%x\n", frame.x8, frame.x9, frame.x10, frame.x11)
        kprintf(" x12-x15: 0x%x - 0x%x - 0x%x - 0x%x\n", frame.x12, frame.x13, frame.x14, frame.x15)
        kprintf(" x16-x19: 0x%x - 0x%x - 0x%x - 0x%x\n", frame.x16, frame.x17, frame.x18, frame.x19)
        kprintf(" x20-x23: 0x%x - 0x%x - 0x%x - 0x%x\n", frame.x20, frame.x21, frame.x22, frame.x23)
        kprintf(" x24-x27: 0x%x - 0x%x - 0x%x - 0x%x\n", frame.x24, frame.x25, frame.x26, frame.x27)
        kprintf(" x28-x29: 0x%x - 0x%x\n", frame.x28, frame.x29)
        kprintf(" lr(x30): 0x%x\n", frame.x30)
    }


    private static func formatCallTrace(_ report: PanicReport) {
        guard let frame = report.frame else { return }

        kprint()
        kprint("Call Trace:")
        kprintf("  [<0x%x>] (PC/ELR)\n", frame.elr)
        kprintf("  [<0x%x>] (LR/x30)\n", frame.x30)

        Arch.CPU.printStackTrace(frame.x29)
    }
}
