//
//  SharedMemory.swift
//  ReixOS
//
//  Created by Eliomar on 31/07/2026.
//


/// A shared-memory region returned by `shmCreate`: the capability `handle`
/// (grant it to a peer over an endpoint, the peer maps it with `shmMap`) and
/// the `address` it is mapped at in *this* process.
public struct SharedMemory {
    public let handle : UInt32
    public let address: UInt64

    /// `true` when the region was created and mapped successfully.
    public var isValid: Bool { handle != UInt32.max }
}
