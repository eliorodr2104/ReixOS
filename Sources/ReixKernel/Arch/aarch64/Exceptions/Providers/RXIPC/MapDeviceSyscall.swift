//
//  MapDeviceSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 28/06/2026.
//

import ReixABI

/// `mapDevice(handle)` syscall provider.
///
/// Same rule as `ShmMap`, applied to MMIO: the window is read-only when the
/// device capability lacks `.write` and refused when it lacks `.read`. A driver
/// that only samples a status register has no business holding a capability
/// that can also drive the device, and until `cap.rights` was consulted here it
/// could not be given anything weaker.
///
/// **A window is mappable only when it is whole pages, aligned.** The smallest
/// unit of translation this architecture has is the 4 KiB page, so mapping a
/// 512-byte window hands over the 3584 bytes beside it as well, which on this
/// machine is seven other devices: the virtio slots are 512 bytes each and eight
/// of them share a page. Rounding up, which is what this did, was quietly
/// granting authority over hardware nobody named.
///
/// The refusal is not a dead end. A window too small to map is reached through
/// `deviceRead`/`deviceWrite`, where the kernel bounds every access against the
/// extent the capability actually names. Two accesses per request is nothing
/// for a device whose data path is in memory; it would be ruinous for one
/// written a byte at a time, which is why the UART, whose window is exactly one
/// page, still maps.
public struct MapDeviceSyscall: SyscallProvider {

    public static let number: SyscallNumber = .mapDevice

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        
        guard let current   = Arch.CPU.getCurrentProcess(),
              let vmaManager = current.pointee.addressSpace.vmaManager
        else { frame.pointee.x0 = 0; return }

        let handle = UInt32(truncatingIfNeeded: frame.pointee.x0)

        guard let cap = current.pointee.metadata.pointee.capsTable.resolve(handle) else {
            frame.pointee.x0 = 0
            return
        }

        guard case .device(let device) = cap.target else {
            frame.pointee.x0 = 0
            return
        }

        guard let permissions = VMAPermissions(mapping: cap.rights) else {
            frame.pointee.x0 = 0
            return
        }

        let pageSize = UserSpaceLayout.pageSize

        guard device.size >= pageSize,
              device.size  % pageSize == 0,
              device.address % pageSize == 0
        else {
            frame.pointee.x0 = 0
            return
        }

        do {
            let vaddr = try vmaManager.pointee.mapRegion(
                physicalBase: device.address,
                pageCount   : Int(device.size / pageSize),
                kind        : .device,
                permissions : permissions
            )
            frame.pointee.x0 = vaddr
            
        } catch { frame.pointee.x0 = 0 }
    }
}
