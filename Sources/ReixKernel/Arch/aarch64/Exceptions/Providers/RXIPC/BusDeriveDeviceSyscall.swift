//
//  BusDeriveDeviceSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// `busDeriveDevice(handle, index) -> handle` syscall provider.
///
/// Carves the `index`th transport's window out of a bus and answers a capability
/// for it, or `UInt32.max` widened, which no handle can be.
///
/// An index and not an offset. The caller used to name a byte offset and a
/// width, so a bus with a gap in it - or one whose windows had merely been
/// summarised into a span - would hand out whatever was sitting in the gap. The
/// only windows that exist now are the ones the device tree declared, and the
/// index picks one of those or nothing.
///
/// The window is exactly what the blob said, never rounded: a 512 byte slot
/// stays 512 bytes, which is what keeps it under the size where `mapDevice`
/// would hand over its neighbours. Rights are intersected with the bus's own, so
/// a bus held read-only cannot mint something that writes, and a bus without
/// `.dma` cannot mint a window that turns into a physical address.
public struct BusDeriveDeviceSyscall: SyscallProvider {

    public static let number: SyscallNumber = .busDeriveDevice

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let metadata = current.pointee.metadata,
              frame.pointee.x1 <= UInt64(UInt32.max),
              let found = BusAccess.authority(handle: frame.pointee.x0, of: current),
              let slot  = found.bus.pointee.bus.transport(
                  at: UInt32(truncatingIfNeeded: frame.pointee.x1)
              )
        else {
            frame.pointee.x0 = UInt64(UInt32.max)
            return
        }

        let window = DeviceRegion(address: slot.base, size: UInt64(slot.size))

        let rights = found.rights.intersection([.read, .write, .grant, .derive, .dma])

        guard let handle = metadata.pointee.capsTable.install(
            Capability(target: .device(window), badge: Badge(0), rights: rights)
        ) else {
            frame.pointee.x0 = UInt64(UInt32.max)
            return
        }

        frame.pointee.x0 = UInt64(handle)
    }
}
