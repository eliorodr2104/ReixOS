//
//  PPMBackend.swift
//  ReixOS
//
//  Created by Eliomar on 21/06/2026.
//

import ReixABI

struct PPMBackend: SlabBackend {
    
    let ppmPtr: UnsafeMutablePointer<KernelPPM>
    static let physicalOffset: UInt64 = 0xFFFF800000000000

    func acquirePage() -> UnsafeMutableRawPointer? {
        guard let page = try? ppmPtr.pointee.alloc(4096) else { return nil }
        
        return UnsafeMutableRawPointer(bitPattern: UInt(page.address + Self.physicalOffset))
    }
    
    func releasePage(_ page: UnsafeMutableRawPointer) {
        let idx = frameIndex(page)
        
        ppmPtr.pointee.framesMetadata![idx].heapShift = 0
        ppmPtr.pointee.framesMetadata![idx].heapFreeCount = 0
        
        try? ppmPtr.pointee.free(PhysicalPage(address: phys(page), order: 0))
    }
    
    func bind(page: UnsafeMutableRawPointer, shift: UInt8) {
        
        let idx = frameIndex(page)
        ppmPtr.pointee.framesMetadata![idx].heapShift = shift
        ppmPtr.pointee.framesMetadata![idx].heapFreeCount = UInt16(4096 / (1 << Int(shift)) - 1)
    }
    
    func shift(ofPage page: UnsafeMutableRawPointer) -> UInt8 {
        ppmPtr.pointee.framesMetadata![frameIndex(page)].heapShift
    }
    
    func onAllocBlock(page: UnsafeMutableRawPointer) {
        
        let idx = frameIndex(page)
        if ppmPtr.pointee.framesMetadata![idx].heapFreeCount > 0 {
            ppmPtr.pointee.framesMetadata![idx].heapFreeCount -= 1
        }
    }
    
    func onFreeBlock(page: UnsafeMutableRawPointer) -> Bool {
        let idx = frameIndex(page)
        ppmPtr.pointee.framesMetadata![idx].heapFreeCount += 1
        let blockCount = UInt16(4096 / (1 << Int(ppmPtr.pointee.framesMetadata![idx].heapShift)))
        
        return ppmPtr.pointee.framesMetadata![idx].heapFreeCount >= blockCount
    }

    @inline(__always)
    private func phys(_ page: UnsafeMutableRawPointer) -> UInt64 {
        UInt64(UInt(bitPattern: page)) - Self.physicalOffset
    }
    
    @inline(__always)
    private func frameIndex(_ page: UnsafeMutableRawPointer) -> Int {
        Int(((phys(page) & ~UInt64(0xFFF)) - ppmPtr.pointee.ramStart) / 4096)
    }
}
