//
//  Endpoint.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


public struct Endpoint {
    public var state    : EndpointState = .idle
    
    public var queueHead: UnsafeMutablePointer<Process>?
    public var queueTail: UnsafeMutablePointer<Process>?
}
