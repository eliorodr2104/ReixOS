//
//  KernelDeadlineKind.swift
//  ReixOS
//
//  Created by Eliomar on 22/08/2026.
//

@usableFromInline
enum KernelDeadlineKind: UInt8 {
    case none
    case sleep
    case ipc

    /// A driver parked in `irqWait` with a deadline, so that a device which has
    /// stopped answering stops one process rather than everything above it.
    case irq
}
