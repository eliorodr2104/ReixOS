//
//  PPMBackend.swift
//  ReixOS
//
//  Created by Eliomar on 21/06/2026.
//

import ReixABI

struct PPMBackend: SlabBackend {
    
    let ppmPtr: UnsafeMutablePointer<KernelPPM>

    static var physicalOffset: UInt64 = 0xFFFF800000000000

    func acquirePage() -> UnsafeMutableRawPointer? {
        guard let page = try? ppmPtr.pointee.alloc(4096) else { return nil }

        let (virtual, overflow) = page.address.addingReportingOverflow(Self.physicalOffset)
        guard !overflow else {
            try? ppmPtr.pointee.free(page)
            return nil
        }

        return UnsafeMutableRawPointer(bitPattern: UInt(virtual))
    }
    
    func releasePage(_ page: UnsafeMutableRawPointer) {
        guard owns(page: page) else { return }
        let idx = frameIndex(page)

        guard (try? ppmPtr.pointee.free(PhysicalPage(address: phys(page), order: 0))) != nil
        else { return }

        ppmPtr.pointee.framesMetadata![idx].heapShift = 0
        ppmPtr.pointee.framesMetadata![idx].heapAllocationBits = 0
    }

    @inline(__always)
    func owns(page: UnsafeMutableRawPointer) -> Bool {
        guard ppmPtr.pointee.framesMetadata != nil else { return false }

        let raw = UInt64(UInt(bitPattern: page))
        guard raw >= Self.physicalOffset else { return false }

        let physical = raw - Self.physicalOffset
        guard physical >= ppmPtr.pointee.ramStart else { return false }

        let offset = physical - ppmPtr.pointee.ramStart
        return (physical & UInt64(0xFFF)) == 0
            && (offset >> 12) < ppmPtr.pointee.totalPages
    }
    
    func bind(page: UnsafeMutableRawPointer, shift: UInt8) {
        let idx = frameIndex(page)
        let blockCount = 4096 / (1 << Int(shift))
        let reserved = SlabCore<Self>.reservedBlockCount(forShift: shift)

        ppmPtr.pointee.framesMetadata![idx].heapShift = shift
        if shift < 8 {
            ppmPtr.pointee.framesMetadata![idx].heapSmallFreeCount = UInt16(blockCount - reserved)
        } else {
            ppmPtr.pointee.framesMetadata![idx].heapAllocationBits = 0
        }
    }
    
    func shiftIfOwned(ofPage page: UnsafeMutableRawPointer) -> UInt8? {
        guard owns(page: page) else { return nil }
        let shift = ppmPtr.pointee.framesMetadata![frameIndex(page)].heapShift
        return shift == 0 ? nil : shift
    }

    func isAllocatedBlock(
        page      : UnsafeMutableRawPointer,
        blockIndex: Int,
        shift     : UInt8
    ) -> Bool {
        if shift < 8 { return slabPageBitIsSet(page: page, blockIndex: blockIndex) }

        let bits = ppmPtr.pointee.framesMetadata![frameIndex(page)].heapAllocationBits
        return (bits & (UInt16(1) << UInt16(blockIndex))) != 0
    }
    
    func onAllocBlock(
        page      : UnsafeMutableRawPointer,
        blockIndex: Int,
        shift     : UInt8
    ) -> Bool {
        let idx = frameIndex(page)
        if shift < 8 {
            guard ppmPtr.pointee.framesMetadata![idx].heapSmallFreeCount > 0,
                  slabTransitionPageBit(
                    page        : page,
                    blockIndex  : blockIndex,
                    expectedLive: false
                  )
            else { return false }
            ppmPtr.pointee.framesMetadata![idx].heapSmallFreeCount -= 1
            return true
        }

        let mask = UInt16(1) << UInt16(blockIndex)
        guard (ppmPtr.pointee.framesMetadata![idx].heapAllocationBits & mask) == 0
        else { return false }
        ppmPtr.pointee.framesMetadata![idx].heapAllocationBits |= mask
        return true
    }
    
    func onFreeBlock(
        page      : UnsafeMutableRawPointer,
        blockIndex: Int,
        shift     : UInt8
    ) -> SlabFreeResult {
        let idx = frameIndex(page)
        if shift >= 8 {
            let mask = UInt16(1) << UInt16(blockIndex)
            guard (ppmPtr.pointee.framesMetadata![idx].heapAllocationBits & mask) != 0
            else { return .invalid }
            ppmPtr.pointee.framesMetadata![idx].heapAllocationBits &= ~mask
            return ppmPtr.pointee.framesMetadata![idx].heapAllocationBits == 0
                ? .releasePage
                : .retained
        }

        let blockCount = 4096 / (1 << Int(shift))
        let reserved = SlabCore<Self>.reservedBlockCount(forShift: shift)
        let usableCount = UInt16(blockCount - reserved)
        guard ppmPtr.pointee.framesMetadata![idx].heapSmallFreeCount < usableCount,
              slabTransitionPageBit(
                page        : page,
                blockIndex  : blockIndex,
                expectedLive: true
              )
        else { return .invalid }

        ppmPtr.pointee.framesMetadata![idx].heapSmallFreeCount += 1

        return ppmPtr.pointee.framesMetadata![idx].heapSmallFreeCount
            == usableCount ? .releasePage : .retained
    }

    @inline(__always)
    private func phys(_ page: UnsafeMutableRawPointer) -> UInt64 {
        UInt64(UInt(bitPattern: page)) - Self.physicalOffset
    }
    
    @inline(__always)
    private func frameIndex(_ page: UnsafeMutableRawPointer) -> Int {
        return Int((phys(page) - ppmPtr.pointee.ramStart) / 4096)
    }
}
