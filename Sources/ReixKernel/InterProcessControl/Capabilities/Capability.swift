//
//  Capability.swift
//  ReixOS
//
//  Created by Eliomar on 24/06/2026.
//

import ReixABI

public struct Capability: Equatable {
    public var target: CapTarget
    public var badge : Badge
    public var rights: CapRights
}
