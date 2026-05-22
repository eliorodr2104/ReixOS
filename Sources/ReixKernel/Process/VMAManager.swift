//
//  VMAManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

public struct VMAManager {
    private var vmaList: LinkedList<VirtualMemoryArea>
    
    init() {
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
        guard let vmaRawPtr = try? KernelHeap.kmalloc(UInt(sizeVMA)) else {
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
            return // Need start a segfault, use interrupt
        }
        
        
        
    }
    
    public func createGuardPage(for region: VirtualMemoryArea) {

    }
}
