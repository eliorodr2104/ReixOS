//
//  OpenFileDescription.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


public struct OpenFileDescription {
    let address      : PhysicalAddress
    let size         : Size
    var currentOffset: Size
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
        size         : Size,
        currentOffset: Size,
        isUsed       : Bool
    ) {
        self.address       = address
        self.size          = size
        self.currentOffset = currentOffset
        self.isUsed        = isUsed
    }
}
