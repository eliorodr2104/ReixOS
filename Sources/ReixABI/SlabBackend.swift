//
//  SlabBackend.swift
//  ReixOS
//
//  Created by Eliomar on 21/06/2026.
//

public protocol SlabBackend {
    
    mutating func acquirePage() -> UnsafeMutableRawPointer?
    mutating func releasePage(_ page: UnsafeMutableRawPointer)

    mutating func bind(page: UnsafeMutableRawPointer, shift: UInt8)
    func shift(ofPage page: UnsafeMutableRawPointer) -> UInt8

    mutating func onAllocBlock(page: UnsafeMutableRawPointer)
    mutating func onFreeBlock(page: UnsafeMutableRawPointer) -> Bool
}

@inline(__always)
public func roundUpPow2(_ value: UInt) -> UInt {
    guard !(value > 0 && (value & (value - 1)) == 0) else { return value }
    
    return 1 &<< (UInt.bitWidth - value.leadingZeroBitCount)
}
