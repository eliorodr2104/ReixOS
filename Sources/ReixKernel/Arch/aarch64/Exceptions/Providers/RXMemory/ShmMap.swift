//
//  ShmMap.swift
//  ReixOS
//
//  Created by Eliomar on 28/06/2026.
//

import ReixABI

/// `shmMap(handle, writable)` syscall provider. A writable request is refused
/// before mapping unless the capability carries write authority. Zero keeps
/// the original behavior of deriving permissions from the capability.
///
/// The window this hands back is only as strong as the capability asked for it:
/// a region capability without `.write` is mapped read-only, one without
/// `.read` is refused. Resolving the handle and checking that its target really
/// is a shared region says who may map, `cap.rights` is the only thing that
/// says *how*, and until it was read here, every holder got read/write.
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

        guard frame.pointee.x1 <= 1,
              frame.pointee.x1 == 0 || cap.rights.contains(.write),
              let permissions = VMAPermissions(mapping: cap.rights) else {
            frame.pointee.x0 = 0
            return
        }

        do {
            let vaddr = try vmaManager.pointee.mapRegion(
                physicalBase: region.pointee.physicalPage.address,
                pageCount   : Int(region.pointee.pageCount),
                kind        : .shared,
                permissions : permissions,
                sharedRegion: region
            )
            frame.pointee.x0 = vaddr
            
        } catch { frame.pointee.x0 = 0 }
    }
}
