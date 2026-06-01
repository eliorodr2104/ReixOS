//
//  Endpoint.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


public struct Endpoint: RXObject {
    public static var errorMessageAllocation: String = "Failed to allocate IPC endpoint"
    
    public var state: EndpointState = .idle
    public var queue: LinkedList<Process>
    
}
