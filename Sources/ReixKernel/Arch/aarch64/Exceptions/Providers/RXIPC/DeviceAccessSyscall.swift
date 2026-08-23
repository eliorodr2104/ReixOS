//
//  DeviceAccessSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// Turning a handle and an offset into one bounded register address.
///
/// The whole point of these two syscalls is here: `DeviceRegion.size` stops
/// being the number of bytes to map and becomes the number of bytes the holder
/// may touch. A window smaller than a page cannot be handed over by the memory
/// unit without its neighbours, so it is handed over one access at a time
/// instead, and this is the check that makes that true.
enum DeviceAccess {

    /// Registers are 32 bits wide on every device this kernel has met, and an
    /// unaligned access to a device register is not slow, it is undefined.
    static let width: UInt64 = 4

    static func address(
        handle : UInt64,
        offset : UInt64,
        needing right: CapRights,
        of process: UnsafeMutablePointer<Process>
    ) -> UnsafeMutableRawPointer? {

        guard handle <= UInt64(UInt32.max),
              let metadata   = process.pointee.metadata,
              let capability = metadata.pointee.capsTable.resolve(UInt32(handle)),
              case .device(let device) = capability.target,
              capability.rights.contains(right)
        else { return nil }

        guard offset % Self.width == 0,
              offset <= device.size,
              device.size - offset >= Self.width
        else { return nil }

        // Reachable because the kernel maps every window it mints: the device
        // tree is the only source of a device capability, and what discovery
        // finds is mapped into the high half at boot beside the UART and the GIC.
        return UnsafeMutableRawPointer(
            bitPattern: UInt(VirtualMemoryManager.physicalOffset &+ device.address &+ offset)
        )
    }
}


/// `deviceRead(handle, offset) -> value` syscall provider.
///
/// Answers the 32-bit register zero-extended, or `UInt64.max` on refusal, which
/// no successful read can be: the top thirty-two bits of an answer are always
/// clear.
public struct DeviceReadSyscall: SyscallProvider {

    public static let number: SyscallNumber = .deviceRead

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let address = DeviceAccess.address(
                  handle : frame.pointee.x0,
                  offset : frame.pointee.x1,
                  needing: .read,
                  of     : current
              )
        else {
            frame.pointee.x0 = UInt64.max
            return
        }

        frame.pointee.x0 = UInt64(mmioRead32(address))
    }
}


/// `deviceWrite(handle, offset, value)` syscall provider.
///
/// Answers `0`, or `UInt64.max` when the handle names no device, the capability
/// does not carry `write`, or the offset falls outside the window.
public struct DeviceWriteSyscall: SyscallProvider {

    public static let number: SyscallNumber = .deviceWrite

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let address = DeviceAccess.address(
                  handle : frame.pointee.x0,
                  offset : frame.pointee.x1,
                  needing: .write,
                  of     : current
              )
        else {
            frame.pointee.x0 = UInt64.max
            return
        }

        mmioWrite32(address, UInt32(truncatingIfNeeded: frame.pointee.x2))
        frame.pointee.x0 = 0
    }
}
