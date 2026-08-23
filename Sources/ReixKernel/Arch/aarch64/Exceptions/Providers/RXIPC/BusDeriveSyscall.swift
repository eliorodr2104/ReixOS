//
//  BusDeriveSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// Resolving a handle to the bus it names.
enum BusAccess {

    static func authority(
        handle : UInt64,
        of process: UnsafeMutablePointer<Process>
    ) -> (bus: UnsafeMutablePointer<BusAuthority>, rights: CapRights)? {

        guard handle <= UInt64(UInt32.max),
              let metadata   = process.pointee.metadata,
              let capability = metadata.pointee.capsTable.resolve(UInt32(handle)),
              case .bus(let bus) = capability.target,
              capability.rights.contains(.derive)
        else { return nil }

        return (bus, capability.rights)
    }
}


/// `busDeriveDevice(handle, offset, size) -> handle` syscall provider.
///
/// Carves one transport's window out of a bus and answers a capability for it,
/// or `UInt32.max` widened, which no handle can be.
///
/// The window it carves is exactly what was asked for, never rounded: a 512
/// byte slot stays 512 bytes, which is what keeps it under the size where
/// `mapDevice` would hand over its neighbours. Rights are intersected with the
/// bus's own, so a bus held read-only cannot mint something that writes.
public struct BusDeriveDeviceSyscall: SyscallProvider {

    public static let number: SyscallNumber = .busDeriveDevice

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        let offset = frame.pointee.x1
        let size   = frame.pointee.x2

        guard let current = Arch.CPU.getCurrentProcess(),
              let metadata = current.pointee.metadata,
              let found = BusAccess.authority(handle: frame.pointee.x0, of: current),
              found.bus.pointee.covers(offset: offset, width: size)
        else {
            frame.pointee.x0 = UInt64(UInt32.max)
            return
        }

        let window = DeviceRegion(
            address: found.bus.pointee.base &+ offset,
            size   : size
        )

        let rights = found.rights.intersection([.read, .write, .grant, .derive])

        guard let handle = metadata.pointee.capsTable.install(
            Capability(target: .device(window), badge: Badge(0), rights: rights)
        ) else {
            frame.pointee.x0 = UInt64(UInt32.max)
            return
        }

        frame.pointee.x0 = UInt64(handle)
    }
}


/// `busDeriveInterrupt(handle, index) -> handle` syscall provider.
///
/// Carves the line of the `index`th transport out of a bus and answers a
/// capability that waits on it. The index is counted from the base of the bus,
/// the same way the window offset is, so a bus process names the slot it just
/// read rather than an interrupt number it would have to have been told.
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
              let line = found.bus.pointee.line(at: index),
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
