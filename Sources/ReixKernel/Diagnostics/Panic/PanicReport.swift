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
public struct PanicReport {

    public let reason   : String?
    public let exception: Exception?
    public let frame    : Arch.TrapFrame?
    public let pid      : PID?

    public init(
        reason   : String?         = nil,
        exception: Exception?      = nil,
        frame    : Arch.TrapFrame? = nil,
        pid      : PID?            = nil
    ) {
        self.reason    = reason
        self.exception = exception
        self.frame     = frame
        self.pid       = pid
    }
}
