//
//  ShellModuleRegistry.swift
//  ReixOS
//
//  Created on 30/08/2026.
//

import ReixABI
import ShellLanguage

/// The modules built into one shell, recorded once for every consumer.
///
/// Adding a module is one merge in `builtIn()`. Its declarations enter the
/// catalog, its handlers enter dispatch, and its live completion hook enters
/// the editor through the same entry.
struct ShellModuleRegistry {
    static let capacity = ShellCatalog.namespaceCapacity

    struct Entry {
        let first : Int
        let count : Int
        let value : (UInt16, inout ShellSession) -> TypedShellInvocationResult?
        let fill  : (inout Command, UInt16, Int) -> Bool
        let handle: (Command, inout ShellSession) -> ShellCommandResult
        let complete: (
            ShellModuleCompletionRequest,
            inout ShellSession,
            inout ShellCompletionSet
        ) -> Void
    }

    private var entries = InlineArray<8, Entry?>(repeating: nil)
    private(set) var count = 0
    private(set) var catalog = ShellCatalog()

    mutating func merge<Module: ShellModule>(_ module: Module.Type) -> Bool {
        guard count < entries.count else { return false }
        let first = catalog.count
        guard catalog.merge(module) else { return false }
        entries[count] = Entry(
            first : first,
            count : Module.commandCount,
            value : { code, session in Module.value(for: code, in: &session) },
            fill  : { command, code, cursor in Module.fill(&command, for: code, at: cursor) },
            handle: { command, session in Module.handleResult(command, in: &session) },
            complete: { request, session, offered in
                Module.complete(request, in: &session, into: &offered)
            }
        )
        count += 1
        return true
    }

    func entry(for command: Int) -> Entry? {
        guard command >= 0, command < catalog.count else { return nil }
        for index in 0..<count {
            guard let entry = entries[index] else { continue }
            if command >= entry.first, command < entry.first + entry.count { return entry }
        }
        return nil
    }

    static func builtIn() -> ShellModuleRegistry {
        var modules = ShellModuleRegistry()
        _ = modules.merge(CoreModule.self)
        _ = modules.merge(ProcessModule.self)
        _ = modules.merge(DiskModule.self)
        _ = modules.merge(FileSystemModule.self)
        return modules
    }
}
