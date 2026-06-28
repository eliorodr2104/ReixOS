//
//  ShmMap.swift
//  ReixOS
//
//  Created by Eliomar on 28/06/2026.
//

import ReixABI

public struct ShmMap: SyscallProvider {
    
    public static let number: SyscallNumber = .shmMap

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

        guard case .shared(let region) = cap.target else {
            frame.pointee.x0 = 0
            return
        }

        do {
            let vaddr = try vmaManager.pointee.mapShared(
                physicalBase: region.pointee.physicalPage.address,
                pageCount   : Int(region.pointee.pageCount)
            )
            frame.pointee.x0 = vaddr
            
        } catch { frame.pointee.x0 = 0 }
    }
}
