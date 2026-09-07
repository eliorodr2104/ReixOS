//
//  ShellCommandProvider.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// Anything the shell can address, describing itself.
///
/// There is no default here on purpose: whoever speaks the shell's language
/// documents what it answers to, in the same declaration the parser resolves
/// against, or it does not compile. The catalog merges what providers hand it
/// and never invents an entry of its own.
public protocol ShellCommandProvider {

    /// The receiver this provider answers as, and the authority behind it.
    static var namespace: ShellNamespaceDescriptor { get }

    static var commandCount: Int { get }

    /// One command, in the provider's own order. `code` inside the descriptor
    /// is the provider's private name for it; nobody else reads it.
    static func command(at index: Int) -> ShellCommandDescriptor?
}
