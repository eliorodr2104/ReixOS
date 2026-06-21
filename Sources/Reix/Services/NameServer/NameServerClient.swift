//
//  Client.swift
//  ReixOS
//
//  Client-side stub for the Name Server: a human-level API over the IPC.
//

import ReixABI

public struct NameServerClient {

    let endpoint: UInt32

    public init(endpoint: UInt32) { self.endpoint = endpoint }

    /// Resolve a service to a capability, or nil if not registered.
    public func lookup(_ service: Services) -> UInt32? {
        call(handle: endpoint, message: NameServerOperation.lookup.message(for: service)).grantedCap
    }

    /// Register `cap` under `service` (one-way; the cap is granted to the NS).
    public func register(
        _ service  : Services,
        endpoint cap: UInt32,
        rights      : CapRights = [.send, .grant]
    ) {
        _ = send(
            handle     : endpoint,
            message    : NameServerOperation.register.message(for: service),
            grant      : cap,
            grantRights: rights
        )
    }
}
