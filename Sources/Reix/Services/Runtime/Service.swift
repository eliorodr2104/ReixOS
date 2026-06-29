//
//  Service.swift
//  ReixOS
//
//  A userland service declares what it provides; the runtime wires the rest.
//  Capabilities arrive through `Environment`, never through globals.
//

import ReixABI

public protocol Service: UserlandService {
    static var manifest: ServiceManifest { get }

    init(environment: Environment, endpoint: UInt32)
}
