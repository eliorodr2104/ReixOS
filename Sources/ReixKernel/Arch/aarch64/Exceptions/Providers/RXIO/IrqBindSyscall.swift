//
//  IrqBindSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// `irqBind(irqHandle, endpointHandle) -> ok` syscall provider.
///
/// Says where to knock when a line fires: from now on a `receive` on that
/// endpoint answers a device as readily as it answers a client.
///
/// This is the whole of what was missing for a driver to keep more than one
/// request in flight. `irqWait` parks the caller on the line and `receive` parks
/// it on an endpoint; a process is in one place at a time, so a driver could
/// wait for work or wait for its disk and never both, and a queue of eight
/// descriptors had no way to be used however carefully it was written.
///
/// Nothing is queued by this. The event still lives in the set's `pending` bits,
/// which is where it always lived and why a line firing with nobody listening is
/// still not lost. Binding only adds a way to be woken.
///
/// One endpoint per set, and re-binding replaces the old one: two places to knock
/// would mean choosing between them on every interrupt, and the holder of a set
/// is one driver with one loop.
///
/// The set takes a reference on the endpoint, one way round on purpose. A bound
/// endpoint cannot be freed while the set naming it is alive, so the endpoint's
/// back pointer is only ever read while there is a set at the other end of it.
public struct IrqBindSyscall: SyscallProvider {

    public static let number: SyscallNumber = .irqBind

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let metadata = current.pointee.metadata,
              let set = InterruptAuthority.resolve(
                  handle: frame.pointee.x0,
                  of    : current
              ),
              frame.pointee.x1 <= UInt64(UInt32.max),
              let capability = metadata.pointee.capsTable.resolve(
                  UInt32(truncatingIfNeeded: frame.pointee.x1)
              ),
              case .endpoint(let endpoint) = capability.target,

              // The endpoint has to be one this process can *receive* on. Binding
              // to an endpoint it can only send to would be asking to be woken
              // somewhere it never waits.
              capability.rights.contains(.receive)
        else {
            frame.pointee.x0 = UInt64.max
            return
        }

        context.ipc.pointee.bind(interrupts: set, to: endpoint)

        frame.pointee.x0 = 0
    }
}
