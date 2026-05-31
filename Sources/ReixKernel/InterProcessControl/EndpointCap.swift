//
//  EndpointCap.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


public struct EndpointCap {
    public var endpoint: UnsafeMutablePointer<Endpoint>
    public var badge   : Badge
    public var rights  : CapRights

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
