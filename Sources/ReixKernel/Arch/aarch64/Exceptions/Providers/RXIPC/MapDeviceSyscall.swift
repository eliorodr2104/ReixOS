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

        do {
            let vaddr = try vmaManager.pointee.mapRegion(
                physicalBase: device.address,
                pageCount   : Int((device.size + UserSpaceLayout.pageSize - 1) / UserSpaceLayout.pageSize),
                kind        : .device,
                permissions : permissions
            )
            frame.pointee.x0 = vaddr
            
        } catch { frame.pointee.x0 = 0 }
    }
}
