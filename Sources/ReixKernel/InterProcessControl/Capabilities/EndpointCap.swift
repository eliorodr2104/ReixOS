//
//  EndpointCap.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

public typealias Badge = UInt32

public struct EndpointCap {
    public var endpoint: UnsafeMutablePointer<Endpoint> // 8 Byte
    public var badge   : Badge                          // 4 Byte
    public var rights  : CapRights                      // 1 Byte

    public init(
        endpoint: UnsafeMutablePointer<Endpoint>,
        badge   : Badge,
        rights  : CapRights
    ) {
        
        self.endpoint = endpoint
        self.badge    = badge
        self.rights   = rights
        
    }
}
