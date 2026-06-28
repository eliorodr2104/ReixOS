//
//  ShmCreate.swift
//  ReixOS
//
//  Created by Eliomar on 28/06/2026.
//

import ReixABI

public struct ShmCreate: SyscallProvider {

    public static let number: SyscallNumber = .shmCreate

    private static let maxPages: UInt64 = 256

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        
        guard let current   = Arch.CPU.getCurrentProcess(),
              let vmaManager = current.pointee.addressSpace.vmaManager
        else {
            frame.pointee.x0 = UInt64.max
            return
        }

        let pageCount = frame.pointee.x0
        guard pageCount > 0, pageCount <= Self.maxPages else {
            frame.pointee.x0 = UInt64.max
            return
        }

        // Allocate the contiguous physical block.
        let physicalPage: PhysicalPage
        do {
            physicalPage = try context.ppm.pointee.alloc(Int(pageCount * UserSpaceLayout.pageSize))
            
        } catch {
            frame.pointee.x0 = UInt64.max
            return
        }

        
        let regionAddress: VirtualAddress
        do {
            regionAddress = try vmaManager.pointee.mapRegion(
                physicalBase: physicalPage.address,
                pageCount   : Int(pageCount),
                kind        : .shared
            )
        } catch {
            try? context.ppm.pointee.free(physicalPage)
            frame.pointee.x0 = UInt64.max
            return
        }


        switch context.ipc.pointee.createShared(
            for      : current,
            page     : physicalPage,
            pageCount: UInt32(pageCount)
        ) {
            case .success(let handle):
                frame.pointee.x0 = UInt64(handle)
                frame.pointee.x1 = regionAddress

            case .failure:
                try? vmaManager.pointee.munmapRegion(
                    addr: regionAddress,
                    size: pageCount * UserSpaceLayout.pageSize
                )
                frame.pointee.x0 = UInt64.max
        }
    }
}

