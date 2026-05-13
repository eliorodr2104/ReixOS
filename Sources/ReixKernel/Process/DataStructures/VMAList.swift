//
//  DoubleLinkedList.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

extension LinkedList: VMAStructure where T == VirtualMemoryArea {
    
    public init(
        head: UnsafeMutablePointer<T>?,
        tail: UnsafeMutablePointer<T>?,
        minAddress: VirtualAddress?,
        maxAddress: VirtualAddress?
    ) {
        self.head = head
        self.tail = tail
        
        self.minAddress = minAddress
        self.maxAddress = maxAddress
    }
    
    
    public func search(at address: VirtualAddress) -> UnsafeMutablePointer<VirtualMemoryArea>? {
        var current = head
                
        while let elementPtr = current {
            let element = elementPtr.pointee
            
            if element.startAddress <= address && address < element.endAddress {
                return elementPtr
            }
            
            current = elementPtr.pointee.next
        }
        
        return nil
    }
    
    
    public mutating func insert(_ region: UnsafeMutablePointer<VirtualMemoryArea>) {
        var current = head
        
        while let elementPtr = current {
            let element = elementPtr.pointee
            
            // e.end < r.start
            if element.startAddress > region.pointee.startAddress {
                
                guard region.pointee.endAddress <= element.startAddress else {
                    return // Implement error, InvalidMemoryConfiguration
                }
                
                if let prevPtr = element.prev {
                    guard prevPtr.pointee.endAddress <= region.pointee.startAddress else {
                        return // Implement error, InvalidMemoryConfiguration
                    }
                }
                
                insertBefore(element: region, to: elementPtr)
                return
            }
            
            current = element.next
        }
        
        if let lastPtr = tail {
            guard lastPtr.pointee.endAddress <= region.pointee.startAddress else {
                return
            }
        }
        
        pushBack(region)
    }
    
    
    public mutating func delete(at address: VirtualAddress) {
        guard let currentNode = search(at: address) else {
            return // Implement Error, searching failh
        }
        
        guard let deletedNode = remove(element: currentNode) else {
            return // Implement Error, removing failed
        }
        
        // Free node because is not more usable
        KernelHeap.kfree(deletedNode)
    }
    
    public func findFreeGAP(
        size     : UInt64,
        alignment: UInt64
    ) -> VirtualAddress? {
        
        guard let minAddress = self.minAddress,
              let maxAddress = self.maxAddress else {
            return nil // Implement Error, min address not setted
        }
        
        var currentMinAddress = minAddress
        var current           = head
        
        while let node = current {
            
            let alignedStart = align(currentMinAddress, to: alignment)
            
            if alignedStart + size <= node.pointee.startAddress {
                return alignedStart
            }
            
            current           = node.pointee.next
            currentMinAddress = node.pointee.endAddress
        }
        
        let lastAlignedStart = align(currentMinAddress, to: alignment)
        if lastAlignedStart + size <= maxAddress {
            return lastAlignedStart
        }
        
        return nil
    }

    
    @inline(__always)
    private func align(
        _  address  : VirtualAddress,
        to alignment: UInt64
    ) -> VirtualAddress { (address + (alignment - 1)) & ~(alignment - 1) }
}
