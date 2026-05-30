//
//  OpenFileDescription.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


public struct OpenFileDescription {
    let address      : VirtualAddress
    let size         : Size
    var currentOffset: Size
    let isUsed       : Bool
    
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
        address      : VirtualAddress,
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
