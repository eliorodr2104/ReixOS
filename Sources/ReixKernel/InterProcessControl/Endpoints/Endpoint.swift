//
//  Endpoint.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


public struct Endpoint: RXObject {
    public static var errorMessageAllocation: String = "Failed to allocate IPC endpoint"
    public static var kernelOwner           : PID    = PID.max

    public var state: EndpointState = .idle
    public var queue: LinkedList<Process>

    /// PID of the process that created this endpoint. Used to reclaim the
    /// endpoint when its owner exits (see `RendezvousIPC.releaseEndpoints`),
    /// so the fixed 64-slot endpoint table isn't leaked one slot per spawned
    /// endpoint.
    public var owner: PID = 0

}
