//
//  Capability.swift
//  ReixOS
//
//  Created by Eliomar on 24/06/2026.
//

import ReixABI

public struct Capability: Equatable {
    public var target: CapTarget

    /// Session token.
    ///
    /// `transferCapability`/`injectCapability` copy this value unchanged, so it
    /// says *which conversation* a message belongs to and can say nothing about
    /// who sent it: the sender's principal is `Process.identity` and travels in
    /// the other half of `x6`. 
    ///
    /// `0` means "no session", and is set-once-from-zero through `CapsTable.mint`:
    /// a cap already bound to a session can never be rebound, or its holder could
    /// recycle a stale session into a server's per-client state.
    public var badge : Badge
    public var rights: CapRights
}
