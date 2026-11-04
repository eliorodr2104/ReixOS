//
//  ShellNamespaceDescriptor.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// One receiver of the language, and the authority its commands act through.
public struct ShellNamespaceDescriptor {
    public let name      : StaticString
    public let capability: BootCap?
    public let summary   : StaticString

    public init(
        _ name      : StaticString,
          capability: BootCap? = nil,
          summary   : StaticString
    ) {
        self.name = name
        self.capability = capability
        self.summary = summary
    }
}
