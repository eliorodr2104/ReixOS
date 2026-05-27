//
//  DoubleLinkedList.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

extension LinkedList: VMAStructure where T == VirtualMemoryArea {

    public init(
        head      : UnsafeMutablePointer<T>?,
        tail      : UnsafeMutablePointer<T>?,
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


    public func searchOverlap(
        start: VirtualAddress,
        end  : VirtualAddress
    ) -> UnsafeMutablePointer<VirtualMemoryArea>? {
        var current = head

        while let elementPtr = current {
            let element = elementPtr.pointee

            if element.startAddress < end && start < element.endAddress {
                return elementPtr
            }

            if element.startAddress >= end {
                return nil
            }

            current = element.next
        }

        return nil
    }


    public mutating func insert(_ region: UnsafeMutablePointer<VirtualMemoryArea>) {
        var current = head

        while let elementPtr = current {
            let element = elementPtr.pointee

            if element.startAddress > region.pointee.startAddress {

                guard region.pointee.endAddress <= element.startAddress else {
                    return
                }

                if let prevPtr = element.prev {
                    guard prevPtr.pointee.endAddress <= region.pointee.startAddress else {
                        return
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
            return
        }

        remove(element: currentNode)

        _ = currentNode
    }

    
    @inline(__always)
    public func findFreeGAP(
        size     : UInt64,
        alignment: UInt64
    ) -> VirtualAddress? {

        guard let minAddress = self.minAddress,
              let maxAddress = self.maxAddress else {
            return nil
        }

        return findFreeGAPInRange(
            min      : minAddress,
            max      : maxAddress,
            size     : size,
            alignment: alignment,
            direction: .upward
        )
    }


    @inline(__always)
    public func findFreeGAPInRange(
        min      : VirtualAddress,
        max      : VirtualAddress,
        size     : UInt64,
        alignment: UInt64,
        direction: GapDirection
    ) -> VirtualAddress? {

        guard size > 0,
              max > min,
              max - min >= size
        else { return nil }

        return switch direction {
            case .upward:
                findFreeGAPUpward(
                    min      : min,
                    max      : max,
                    size     : size,
                    alignment: alignment
                )

            case .downward: nil
        }
    }


    public mutating func split(
        _     region : UnsafeMutablePointer<VirtualMemoryArea>,
        at    address: VirtualAddress,
        using heap   : UnsafeMutablePointer<BucketsHeap>
    ) throws(VMAError) -> UnsafeMutablePointer<VirtualMemoryArea> {

        guard address > region.pointee.startAddress,
              address < region.pointee.endAddress
        else { throw .invalidLayout }

        let nodeSize: UInt = UInt(MemoryLayout<VirtualMemoryArea>.stride)

        let allocated: UnsafeMutableRawPointer?
        do {
            allocated = try heap.pointee.kmalloc(nodeSize)
            
        } catch { throw .heapAllocationFailed(error) }

        guard let allocatedRaw = allocated else {
            throw .heapAllocationFailed(.metadataInconsistency)
        }

        let newRegion = allocatedRaw.initializeMemory(
            as       : VirtualMemoryArea.self,
            repeating: VirtualMemoryArea(
                startAddress: address,
                endAddress  : region.pointee.endAddress,
                permissions : region.pointee.permissions,
                backingType : region.pointee.backingType,
                mappingFlags: region.pointee.mappingFlags,
                prev        : nil,
                next        : nil
            ),
            
            count: 1
        )

        let truncated = VirtualMemoryArea(
            startAddress: region.pointee.startAddress,
            endAddress  : address,
            permissions : region.pointee.permissions,
            backingType : region.pointee.backingType,
            mappingFlags: region.pointee.mappingFlags,
            prev        : region.pointee.prev,
            next        : region.pointee.next
        )
        region.pointee = truncated

        insertAfter(element: newRegion, to: region)

        return newRegion
    }


    public mutating func mergeAdjacent(
        _ first : UnsafeMutablePointer<VirtualMemoryArea>,
        _ second: UnsafeMutablePointer<VirtualMemoryArea>
    ) -> UnsafeMutablePointer<VirtualMemoryArea>? {

        guard first.pointee.next                  == second,
              first.pointee.endAddress            == second.pointee.startAddress,
              first.pointee.permissions.rawValue  == second.pointee.permissions.rawValue,
              first.pointee.mappingFlags.rawValue == second.pointee.mappingFlags.rawValue,
              first.pointee.backingType           == second.pointee.backingType
        else { return nil }

        let merged = VirtualMemoryArea(
            startAddress: first.pointee.startAddress,
            endAddress  : second.pointee.endAddress,
            permissions : first.pointee.permissions,
            backingType : first.pointee.backingType,
            mappingFlags: first.pointee.mappingFlags,
            prev        : first.pointee.prev,
            next        : first.pointee.next
        )
        first.pointee = merged

        remove(element: second)
        return second
    }


    private func findFreeGAPUpward(
        min      : VirtualAddress,
        max      : VirtualAddress,
        size     : UInt64,
        alignment: UInt64
    ) -> VirtualAddress? {

        var currentMinAddress = min
        var current           = head

        while let node = current {
            let nodeStart = node.pointee.startAddress
            let nodeEnd   = node.pointee.endAddress

            if nodeEnd <= min {
                current = node.pointee.next
                continue
            }

            if nodeStart >= max { break }

            let alignedStart = align(currentMinAddress, to: alignment)
            
            if alignedStart + size <= nodeStart && alignedStart + size <= max {
                return alignedStart
            }

            current           = node.pointee.next
            currentMinAddress = nodeEnd > currentMinAddress ? nodeEnd : currentMinAddress
        }

        let lastAlignedStart = align(currentMinAddress, to: alignment)
        
        if lastAlignedStart + size <= max { return lastAlignedStart }

        return nil
    }


    @inline(__always)
    private func align(
        _  address  : VirtualAddress,
        to alignment: UInt64
    ) -> VirtualAddress { (address + (alignment - 1)) & ~(alignment - 1) }
}
