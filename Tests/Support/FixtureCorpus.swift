//
//  FixtureCorpus.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.

import Foundation

/// The captured corpora, addressed by path relative to `Tests/Fixtures`.
///
/// Located from `#filePath` rather than from `Bundle.module`. SwiftPM would only
/// give the corpus a bundle by declaring it as a resource of some target, and a
/// target may not reach for files outside its own directory: the corpus would
/// have to move under `Tests/Support`, next to the code, which is the one place
/// a reader would not look for captured binaries. The compile-time path has no
/// such constraint and fails loudly rather than silently returning nothing.
public enum FixtureCorpus {

    /// `Tests/Fixtures`, derived from this file's own location at compile time.
    public static var directory: URL {
        URL(fileURLWithPath: #filePath)      // Tests/Support/FixtureCorpus.swift
            .deletingLastPathComponent()     // Tests/Support
            .deletingLastPathComponent()     // Tests
            .appendingPathComponent("Fixtures")
    }

    public static func url(_ relativePath: String) -> URL {
        directory.appendingPathComponent(relativePath)
    }

    /// The bytes of one fixture, or `nil` when it is missing.
    ///
    /// Optional rather than trapping so a suite can report which artifact it
    /// wanted: a corpus test whose fixture vanished should say so by name.
    public static func bytes(_ relativePath: String) -> [UInt8]? {
        guard let data = try? Data(contentsOf: url(relativePath)) else { return nil }
        return [UInt8](data)
    }


    // MARK: - Named artifacts

    /// The QEMU virt device trees, in the order a reader wants them: the machine
    /// `make run` boots, the one `make run-4m` boots, and the one that carries
    /// `/chosen`'s initrd properties.
    public enum DeviceTree {
        public static let virt128M       = "dtb/virt-gicv2-128m.dtb"
        public static let virt4M         = "dtb/virt-gicv2-4m.dtb"
        public static let virt128MInitrd = "dtb/virt-gicv2-128m-initrd.dtb"

        public static let all = [virt128M, virt4M, virt128MInitrd]
    }

    /// The ustar archive written by the repo's own packer.
    public enum Tar {
        public static let corpus = "tar/corpus.tar"
    }
}
