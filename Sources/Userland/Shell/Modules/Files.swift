//
//  Files.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

/// The file system, if this shell was given a way to find one. Attached once,
/// because attaching costs a page shared with the server.
enum Files {

    nonisolated(unsafe) static var client : FileSystemClient? = nil
    nonisolated(unsafe) static var looked = false

    static func attached(_ environment: Environment) -> FileSystemClient? {
        guard !looked else { return client }
        looked = true

        // Not looked up: handed over. The shell sees the whole machine because
        // init gave it the machine's own container, and a shell started without
        // one would see nothing at all and say so.
        guard let handed = environment.container else { return nil }

        // Deliberately not seeding the shell's place from here: `dispatch` copies
        // the shell's state into the session before any module runs and writes it
        // back afterwards, so anything set here is overwritten by the session
        // that is already in flight. It is seeded where the session is in hand.
        client = FileSystemClient(fileSystem: handed)

        return client
    }
}
