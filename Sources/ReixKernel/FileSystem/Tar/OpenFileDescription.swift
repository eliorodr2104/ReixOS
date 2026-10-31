//
//  OpenFileDescription.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


/// One open member. `currentOffset <= size` always holds: `seek` refuses
/// anything past the end and `read` advances by at most what is left, which is
/// what lets `read` subtract without a check.
public struct OpenFileDescription {
    let address      : PhysicalAddress
    let size         : UInt64
    var currentOffset: UInt64
    let isUsed       : Bool

    // The initrd is identity-mapped, so this physical base doubles as a
    // valid virtual pointer without any translation step.
    var dataPointer: UnsafeRawPointer? {
        UnsafeRawPointer(bitPattern: UInt(address))
    }

    init() {
        self.address       = 0
        self.size          = 0
        self.currentOffset = 0
        self.isUsed        = false
    }

    init(
        address      : PhysicalAddress,
        size         : UInt64,
        currentOffset: UInt64,
        isUsed       : Bool
    ) {
        self.address       = address
        self.size          = size
        self.currentOffset = currentOffset
        self.isUsed        = isUsed
    }
}
