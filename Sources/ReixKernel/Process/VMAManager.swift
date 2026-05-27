//
//  VMAManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

/// Per-address-space owner of the Virtual Memory Areas.
///
/// Currently a scaffolding placeholder: stores a doubly-linked list of
/// VMAs and exposes a stub `memoryMap` that registers a region without
/// performing the actual PTE mapping. The full implementation (lazy
/// mapping, page-fault routing, COW, guard pages, growable stack) lands
/// in step 5 of the VMA milestone.
///
/// The heap pointer is injected to keep the manager aligned with the
/// rest of the kernel POP composition: allocations of VMA nodes go
/// through `heap.pointee.kmalloc` instead of a static facade.
public struct VMAManager {

    private var vmaList: LinkedList<VirtualMemoryArea>

    private let heap: UnsafeMutablePointer<BucketsHeap>

    public init(heap: UnsafeMutablePointer<BucketsHeap>) {
        self.heap    = heap
        self.vmaList = LinkedList(
            head      : nil,
            tail      : nil,
            minAddress: 0,
            maxAddress: 0
        )
    }

    public mutating func memoryMap(
        size       : UInt64,
        permissions: VMAPermissions,
        type       : BackingType
    ) -> VirtualAddress? {

        let alignedSize = (size + 4095) & ~4095
        guard let address = vmaList.findFreeGAP(size: alignedSize, alignment: 4096) else {
            return nil
        }

        let sizeVMA = MemoryLayout<VirtualMemoryArea>.stride
        guard let vmaRawPtr = try? heap.pointee.kmalloc(UInt(sizeVMA)) else {
            return nil
        }

        let vmaPtr = vmaRawPtr.initializeMemory(
            as: VirtualMemoryArea.self,
            repeating: VirtualMemoryArea(
                startAddress: address,
                endAddress  : address + alignedSize,
                permissions : permissions,
                backingType : type,
                mappingFlags: .copyOnWrite
            ),
            count: 1
        )

        vmaList.insert(vmaPtr)

        return address
    }

    public func handlePageFault(at address: VirtualAddress) {

        guard let vma = vmaList.search(at: address) else {
            return
        }

        _ = vma
    }

    public func createGuardPage(for region: VirtualMemoryArea) {

    }
}
