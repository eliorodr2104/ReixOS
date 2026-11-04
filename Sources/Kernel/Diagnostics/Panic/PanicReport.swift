//
//  PanicReport.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Snapshot of the kernel state at the moment a panic is raised.
///
/// Pure data carrier produced by `Arch.CPU.panic` and consumed by a
/// `PanicFormatter`. No logic lives here so the report can be built in
/// the most constrained contexts (kernel abort, panic from IRQ) without
/// allocating or invoking other subsystems.
///
/// The trap frame is borrowed from the exception entry stack. A frame is much
/// larger than the other fields, so embedding it here would make every panic
/// guard reserve space for several complete register images even when no frame
/// was supplied. The caller keeps the frame alive for synchronous formatting,
/// and neither the report nor a formatter may retain the pointer afterwards.
public struct PanicReport {

    public let reason   : StaticString?
    public let exception: Exception?
    public let frame    : UnsafePointer<Arch.TrapFrame>?
    public let pid      : PID?

    public init(
        reason   : StaticString?                  = nil,
        exception: Exception?                     = nil,
        frame    : UnsafePointer<Arch.TrapFrame>? = nil,
        pid      : PID?                           = nil
    ) {
        self.reason    = reason
        self.exception = exception
        self.frame     = frame
        self.pid       = pid
    }
}
