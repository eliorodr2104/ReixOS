//
//  DoubleLinkedList.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

extension LinkedList: VMAStructure where T == VirtualMemoryArea {
    
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
    
    
    public func delete(at address: VirtualAddress) {
        
    }
    
    public func findFreeGAP(size: UInt64, alignment: UInt64) -> VirtualAddress? {
        return nil
    }
    
}
