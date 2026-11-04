//
//  DeviceRegion.swift
//  ReixOS
//
//  Created by Eliomar on 28/06/2026.
//

@frozen
public struct DeviceRegion: Equatable {
    
    public let address   : PhysicalAddress
    public let size      : UInt64

    public init(
        address: PhysicalAddress,
        size   : UInt64
    ) {
        self.address = address
        self.size    = size
    }
}
