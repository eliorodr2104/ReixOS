//
//  VMAList.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

/// The VMA set of one address space: an intrusive chain of regions in ascending
/// address order, plus the window gap finding may hand addresses out of.
///
/// The window is what makes this a type of its own rather than a `LinkedList`
/// extension: `minAddress`/`maxAddress` mean something only here, and every
/// other list in the kernel (the scheduler queues, the endpoint queues, the
/// buddy's free lists) used to carry the two words unset and unread.
public struct VMAList: VMAStructure {

    /// The user window `findFreeGAP` searches, fixed at construction.
    internal let minAddress: VirtualAddress // 8 Byte
    internal let maxAddress: VirtualAddress // 8 Byte

    /// The regions themselves, ordered by `startAddress`.
    internal var nodes: LinkedList<VirtualMemoryArea> // 16 Byte


    internal var head: UnsafeMutablePointer<VirtualMemoryArea>? { nodes.head }
    internal var tail: UnsafeMutablePointer<VirtualMemoryArea>? { nodes.tail }


    public init(
        minAddress: VirtualAddress,
        maxAddress: VirtualAddress
    ) {
        self.minAddress = minAddress
        self.maxAddress = maxAddress
        self.nodes      = LinkedList(head: nil, tail: nil)
    }


    /// Hand the whole chain to the caller and keep an empty list, window intact.
    ///
    /// Teardown's move: the retirement walk frees the nodes it pops, so it must
    /// own them, and nothing may reach a region through the manager afterwards.
    internal mutating func detachAll() -> LinkedList<VirtualMemoryArea> {
        let chain = nodes
        nodes     = LinkedList(head: nil, tail: nil)

        return chain
    }


    /// Unlink `region` without freeing it. The caller owns the node afterwards.
    internal mutating func remove(element region: UnsafeMutablePointer<VirtualMemoryArea>) {
        nodes.remove(element: region)
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

                nodes.insertBefore(element: region, to: elementPtr)
                return
            }

            current = element.next
        }

        if let lastPtr = tail {
            guard lastPtr.pointee.endAddress <= region.pointee.startAddress else {
                return
            }
        }

        nodes.pushBack(region)
    }


    public mutating func delete(at address: VirtualAddress) {
        guard let currentNode = search(at: address) else {
            return
        }

        nodes.remove(element: currentNode)

        _ = currentNode
    }


    @inline(__always)
    public func findFreeGAP(
        size     : UInt64,
        alignment: UInt64
    ) -> VirtualAddress? {

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

            case .downward:
                findFreeGAPDownward(
                    min      : min,
                    max      : max,
                    size     : size,
                    alignment: alignment
                )
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

        guard let newRegionPtr = heap.pointee.kmallocOrNil(VirtualMemoryArea.self) else {
            throw .heapAllocationFailed(.allocationFailed(reason: .fullMemory))
        }

        newRegionPtr.initialize(
            to: VirtualMemoryArea(
                startAddress: address,
                endAddress  : region.pointee.endAddress,
                permissions : region.pointee.permissions,
                backingType : region.pointee.backingType,
                mappingFlags: region.pointee.mappingFlags,
                sharedRegion: region.pointee.sharedRegion
            )
        )

        if let sharedRegion = region.pointee.sharedRegion {
            retainSharedRegion(sharedRegion)
        }

        let truncated = VirtualMemoryArea(
            startAddress: region.pointee.startAddress,
            endAddress  : address,
            permissions : region.pointee.permissions,
            prev        : region.pointee.prev,
            next        : region.pointee.next,
            backingType : region.pointee.backingType,
            mappingFlags: region.pointee.mappingFlags,
            sharedRegion: region.pointee.sharedRegion
        )
        region.pointee = truncated

        nodes.insertAfter(element: newRegionPtr, to: region)

        return newRegionPtr
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

        guard first.pointee.backingType == .anonymous else { return nil }

        let merged = VirtualMemoryArea(
            startAddress: first.pointee.startAddress,
            endAddress  : second.pointee.endAddress,
            permissions : first.pointee.permissions,
            prev        : first.pointee.prev,
            next        : first.pointee.next,
            backingType : first.pointee.backingType,
            mappingFlags: first.pointee.mappingFlags,
            sharedRegion: first.pointee.sharedRegion
        )
        first.pointee = merged

        nodes.remove(element: second)
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


    private func findFreeGAPDownward(
        min      : VirtualAddress,
        max      : VirtualAddress,
        size     : UInt64,
        alignment: UInt64
    ) -> VirtualAddress? {

        var currentMaxAddress = max
        var current           = tail

        while let node = current {
            let nodeStart = node.pointee.startAddress
            let nodeEnd   = node.pointee.endAddress

            if nodeStart >= currentMaxAddress {
                current = node.pointee.prev
                continue
            }

            if nodeEnd <= min { break }

            guard currentMaxAddress >= size else { return nil }

            let candidate = alignDown(currentMaxAddress - size, to: alignment)

            if candidate >= nodeEnd && candidate >= min {
                return candidate
            }

            currentMaxAddress = nodeStart
            current           = node.pointee.prev
        }

        guard currentMaxAddress >= size else { return nil }

        let candidate = alignDown(currentMaxAddress - size, to: alignment)

        if candidate >= min { return candidate }

        return nil
    }


    @inline(__always)
    private func align(
        _  address  : VirtualAddress,
        to alignment: UInt64
    ) -> VirtualAddress { (address + (alignment - 1)) & ~(alignment - 1) }


    @inline(__always)
    private func alignDown(
        _  address  : VirtualAddress,
        to alignment: UInt64
    ) -> VirtualAddress { address & ~(alignment - 1) }
}
