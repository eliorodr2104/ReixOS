//
//  Client.swift
//  ReixOS
//
//

import ReixABI

public struct NameServerClient {

    let endpoint: UInt32

    public init(endpoint: UInt32) { self.endpoint = endpoint }

    /// Resolve a service to a capability, or nil if not registered.
    public func lookup(_ service: Services) -> UInt32? {

        guard case .success(var answer) = call(
            handle : endpoint,
            message: NameServerOperation.lookup.message(for: service)
        ) else { return nil }

        // The capability is the answer. A reply with any other label did not
        // come from a lookup that found something.
        guard answer.message.tag.label == NameServerResponse.ack.rawValue else {
            if let stray = answer.takeGrant() { _ = capDrop(stray) }
            return nil
        }

        return answer.takeGrant()
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
