//
//  BuddyFreeSiteTests.swift
//  ReixOS
//

import Testing
import Foundation

/// The buddy allocator's `free` has exactly one caller, `PhysicalPageManager`.
///
/// A check on the source, like `FrameBudgetSiteTests`. The page manager checks a
/// free against the order it recorded for the block before the buddy sees it;
/// the buddy's own nested-block refusal is the second wall, and this keeps the
/// first one the only door: one instance, held privately, freed from one line.
@Suite("Buddy free call site")
struct BuddyFreeSiteTests {

    private static let manager = "Sources/ReixKernel/Memory/Physical/PhysicalPageManager.swift"


    /// The package root: the nearest ancestor of this file holding `Package.swift`.
    private static var packageRoot: URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path),
              directory.path != "/" {
            directory.deleteLastPathComponent()
        }
        return directory
    }


    @Test("only PhysicalPageManager builds a BuddyAllocator, holds it privately and frees through it, once")
    func singleFreeSite() throws {
        let root    = Self.packageRoot
        let sources = root.appendingPathComponent("Sources")

        guard let walk = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            Issue.record("could not walk \(sources.path)")
            return
        }

        var builds: [String: Int] = [:]
        var frees : [String: Int] = [:]
        var holder = false

        for case let url as URL in walk where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let text = try String(contentsOf: url, encoding: .utf8)

            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }

                if line.contains("BuddyAllocator(") { builds[relative, default: 0] += 1 }
                if line.contains("allocator.free(") { frees[relative, default: 0] += 1 }
                if relative == Self.manager, trimmed.hasPrefix("private let allocator") { holder = true }
            }
        }

        #expect(builds == [Self.manager: 1], "BuddyAllocator built in \(builds)")
        #expect(frees == [Self.manager: 1], "allocator.free called in \(frees)")
        #expect(holder, "PhysicalPageManager no longer holds its allocator as `private let allocator`")
    }
}
