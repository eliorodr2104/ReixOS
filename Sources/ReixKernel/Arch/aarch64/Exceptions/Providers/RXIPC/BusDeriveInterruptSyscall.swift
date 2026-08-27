//
//  BusDeriveInterruptSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// `busDeriveInterrupt(handle, index) -> handle` syscall provider.
///
/// Carves the line of the `index`th transport out of a bus and answers a
/// capability that waits on it. The same index that names the window names the
/// line, so a bus process names the slot it just read rather than an interrupt
/// number it would have to have been told.
///
/// The line is the one the device tree paired with that window. It used to be
/// the first line of the bus plus the index, which is the same answer on a
/// machine whose slots and lines happen to run in step, and a line belonging to
/// some other device on one where they do not.
///
/// A line already claimed is refused rather than taken: two holders of one line
/// is the failure the claims table exists to prevent, and a bus is not an
/// exception to it.
public struct BusDeriveInterruptSyscall: SyscallProvider {

    public static let number: SyscallNumber = .busDeriveInterrupt

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        let index = UInt32(truncatingIfNeeded: frame.pointee.x1)

        guard let current = Arch.CPU.getCurrentProcess(),
              let metadata = current.pointee.metadata,
              let found = BusAccess.authority(handle: frame.pointee.x0, of: current),
              frame.pointee.x1 <= UInt64(UInt32.max),
              let line = found.bus.pointee.bus.transport(at: index)?.line,
              let set = context.ipc.pointee.heap.pointee.kmallocOrNil(InterruptSet.self)
        else {
            frame.pointee.x0 = UInt64(UInt32.max)
            return
        }

        set.initialize(to: InterruptSet())

        guard set.pointee.add(line: line) != nil,
              InterruptClaims.claim(line: line, by: set)
        else {
            context.ipc.pointee.heap.pointee.kfree(set)
            frame.pointee.x0 = UInt64(UInt32.max)
            return
        }

        let rights = found.rights.intersection([.grant, .derive])

        guard let handle = metadata.pointee.capsTable.install(
            Capability(target: .interrupt(set), badge: Badge(0), rights: rights)
        ) else {
            InterruptClaims.releaseAll(of: set)
            context.ipc.pointee.heap.pointee.kfree(set)
            frame.pointee.x0 = UInt64(UInt32.max)
            return
        }

        set.pointee.references = 1
        Kernel.gic.pointee.enableInterrupt(id: line)

        frame.pointee.x0 = UInt64(handle)
    }
}
