//
//  main.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//
//  The catalog, against the modules the shell is actually built with. A harness rather than a suite in ShellTests: the shell's
//  modules pull in Reix, whose freestanding stand-ins for `malloc` and
//  `putchar` collide with the kernel's inside one test bundle.
//

import Foundation
import Reix
import ReixABI
import ShellLanguage
@testable import Shell

private func require(
    _ condition: Bool,
    _ what     : String = "",
      file     : StaticString = #fileID,
      line     : UInt = #line
) {
    if !condition {
        fatalError("Shell catalog harness failure at \(file):\(line) \(what)")
    }
}

private func spelling(_ value: StaticString) -> String {
    String(decoding: UnsafeBufferPointer(start: value.utf8Start, count: value.utf8CodeUnitCount), as: UTF8.self)
}

/// A receiver that claims a name another provider already holds.
private enum Twin: ShellCommandProvider {
    static var namespace: ShellNamespaceDescriptor {
        ShellNamespaceDescriptor("shell", summary: "a second claim on a taken name")
    }
    static var commandCount: Int { 1 }
    static func command(at index: Int) -> ShellCommandDescriptor? {
        ShellCommandDescriptor(
            code     : 0,
            verb     : "help",
            signature: TypedShellSignature(namespace: "shell", name: "help"),
            summary  : "the same receiver, again"
        )
    }
}

/// A provider filing a command under somebody else's receiver.
private enum Impostor: ShellCommandProvider {
    static var namespace: ShellNamespaceDescriptor {
        ShellNamespaceDescriptor("impostor", summary: "declares under a receiver it does not own")
    }
    static var commandCount: Int { 1 }
    static func command(at index: Int) -> ShellCommandDescriptor? {
        ShellCommandDescriptor(
            code     : 0,
            verb     : "read",
            signature: TypedShellSignature(namespace: "fileSystem", name: "borrowed"),
            summary  : "a command filed under somebody else's receiver"
        )
    }
}

private func testModulesMerge() {
    let catalog = ShellPipeline.merged()
    require(catalog.namespaceCount == 4, "namespaces merged")
    require(
        catalog.count == CoreModule.commandCount
            + ProcessModule.commandCount
            + DiskModule.commandCount
            + FileSystemModule.commandCount,
        "every module merged whole"
    )

    for index in 0..<catalog.count {
        guard let descriptor = catalog.command(at: index) else { require(false); return }
        // The receiver a command was merged under is the one it declares,
        // which is what dispatch relies on to find its module again.
        require(
            spelling(descriptor.signature.namespace) == catalog.receiver(ofCommandAt: index).map { spelling($0.name) },
            "receiver of \(spelling(descriptor.signature.name))"
        )
    }
    require(catalog.command(at: catalog.count) == nil)
    require(catalog.receiver(ofCommandAt: -1) == nil)
}

private func testMergeRefusesWhatItCannotName() {
    var catalog = ShellCatalog()
    require(catalog.merge(CoreModule.self), "the first provider merges")
    require(!catalog.merge(Twin.self), "a taken receiver is refused")
    require(catalog.namespaceCount == 1)
    require(catalog.count == CoreModule.commandCount)

    require(!catalog.merge(Impostor.self), "a command under another receiver is refused")
    require(catalog.namespaceIndex(named: "impostor") == nil, "and nothing of it is kept")
}

private func testSignatureTableIsTheCatalog() {
    let catalog = ShellPipeline.merged()
    catalog.withSignatures { signatures in
        require(signatures.count == catalog.count)
        for index in signatures.indices {
            guard let signature = signatures[index], let descriptor = catalog.command(at: index) else {
                require(false)
                return
            }
            require(spelling(signature.name) == spelling(descriptor.signature.name))
            require(spelling(signature.namespace) == spelling(descriptor.signature.namespace))
        }
    }
}

private func testSpellingsResolveUniquely() {
    let catalog = ShellPipeline.merged()
    for first in 0..<catalog.count {
        guard let left = catalog.command(at: first) else { continue }
        for second in (first + 1)..<catalog.count {
            guard let right = catalog.command(at: second) else { continue }
            guard spelling(left.signature.name) == spelling(right.signature.name) else { continue }

            require(spelling(left.signature.namespace) != spelling(right.signature.namespace))

            // Two verbs spelled alike may coexist only when writing the
            // receiver is the one way to tell them apart.
            let bothBare  = !left.signature.namespaceRequired && !right.signature.namespaceRequired
            let sameArity = left.signature.parameterCount == right.signature.parameterCount
            require(!(bothBare && sameArity), "\(spelling(left.signature.name)) is ambiguous without a receiver")
        }
    }
}

private func testEveryCommandNamesItsAuthority() {
    let catalog = ShellPipeline.merged()
    for index in 0..<catalog.count {
        guard let descriptor = catalog.command(at: index) else { continue }
        let name = spelling(descriptor.signature.name)
        if name == "help" || name == "exit" { continue }
        require(descriptor.capability != nil, "\(name) claims no capability")
    }
}

private func testObjectsCarryASchema() {
    let catalog = ShellPipeline.merged()
    for index in 0..<catalog.count {
        guard let descriptor = catalog.command(at: index) else { continue }
        if descriptor.signature.result == .sequence || descriptor.signature.result == .record {
            require(descriptor.schema != .none, "\(spelling(descriptor.signature.name)) answers with unnamed objects")
            require(ShellCatalog.memberCount(of: descriptor.schema) > 0)
        }
    }
    require(ShellCatalog.member(of: .file, at: 0) != nil)
    require(ShellCatalog.member(of: .file, at: ShellCatalog.memberCount(of: .file)) == nil)
}

testModulesMerge()
testMergeRefusesWhatItCannotName()
testSignatureTableIsTheCatalog()
testSpellingsResolveUniquely()
testEveryCommandNamesItsAuthority()
testObjectsCarryASchema()

// `print` would reach Reix's freestanding `putchar`, which has no console
// here. The harness says how it went through the file descriptor instead.
FileHandle.standardOutput.write(Data("ShellCatalogHarness: 6 checks passed\n".utf8))
