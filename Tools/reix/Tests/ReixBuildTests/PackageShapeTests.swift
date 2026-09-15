//
//  PackageShapeTests.swift
//  ReixOS
//

import Testing
import Foundation

/// The build front end must not reach the kernel's build graph. These read the
/// manifests as text on purpose: the requirement is about what is *declared*,
/// and a test that imported the modules would pass even if the root manifest
/// had grown a dependency.
@Suite struct PackageShapeTests {

    static var repoRoot: URL {
        // …/Tools/reix/Tests/ReixBuildTests/PackageShapeTests.swift -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReixBuildTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // reix
            .deletingLastPathComponent()   // Tools
            .deletingLastPathComponent()   // repo root
    }

    @Test func rootManifestHasNoPackageDependencies() throws {
        let manifest = try String(
            contentsOf: Self.repoRoot.appending(path: "Package.swift"), encoding: .utf8
        )
        #expect(!manifest.contains(".package("))
    }

    @Test func swiftTUIIsNamedOnlyInTheCLIManifest() throws {
        let manifest = try String(
            contentsOf: Self.repoRoot.appending(path: "Package.swift"), encoding: .utf8
        )
        #expect(!manifest.lowercased().contains("swifttui"))
    }
}
