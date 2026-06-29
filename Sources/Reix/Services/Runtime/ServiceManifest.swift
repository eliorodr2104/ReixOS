//
//  ServiceManifest.swift
//  ReixOS
//
//  Created by Eliomar on 29/06/2026.
//

import ReixABI

public struct ServiceManifest {

    public enum Provider {
        case none
        case parent
        case nameServer(Services)
    }

    public let provides: Provider

    public init(provides: Provider) {
        self.provides = provides
    }
}
