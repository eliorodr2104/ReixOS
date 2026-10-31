//
//  TarArchiveCorpusTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import KernelTestSupport

/// `TarFileSystem` over the archive the project's own packer writes.
///
/// The fixture is `Tests/Fixtures/tar/corpus.tar`, produced by
/// `Plugins/reix/UstarWriter.swift`, so the layout under test is the one the
/// real initrd has: page-aligned member data bought with `@pad` filler members
/// the walk has to step over like any other entry. See
/// `Tests/Fixtures/tar/README.md` for how it was built and why these member
/// names were chosen.
///
/// The archive is staged with its last byte on the last readable byte of its
/// mapping, so the walk stepping one member past the end faults instead of
/// reading whatever followed, and the mapping is read-only so a filesystem that
/// wrote into the image would fault too.
///
/// The staging parks the archive in `Kernel.platformInfo`, which is
/// process-wide, and `TarFileSystem.init` records the base from it. `.serialized`
/// only orders this suite's own tests, so the run needs
/// `swift test --no-parallel` (see the `test` target in the Makefile).
extension KernelPolicyTestRoot {
@Suite("Tar archive corpus", .serialized)
struct TarArchiveCorpusTests {

    @Test("the packed corpus is the archive its README records")
    func fixtureIsTheDocumentedArchive() {
        guard let archive = FixtureCorpus.bytes(FixtureCorpus.Tar.corpus) else {
            Issue.record("missing fixture")
            return
        }

        #expect(archive.count == 30720)
        #expect(archive.count % 512 == 0)

        guard let members = UstarLayout.members(of: archive) else {
            Issue.record("the archive does not walk to an end-of-archive marker")
            return
        }

        #expect(members.map(\.name) == [
            "@pad", "alpha.txt", "@pad", "al", "@pad", "alpha.txt.bak",
            "@pad", "beta.bin", "@pad", "empty.dat", "@pad", "gamma.bin",
        ])

        for member in members {
            #expect(UstarLayout.hasUstarMagic(archive, headerAt: member.headerOffset))

            // What the packer exists for, and the reason the ELF loader can map
            // a segment straight out of the image. `@pad` members are the price.
            if member.name != "@pad" {
                #expect(member.dataOffset % 4096 == 0)
            }

            #expect(member.dataOffset + member.size <= archive.count)
        }

        // Two zero blocks close the archive, which is what stops the walk.
        #expect(archive.suffix(1024).allSatisfy { $0 == 0 })
    }


    @Test("every member opens, sizes and reads back byte for byte")
    func everyMemberRoundTrips() {
        guard let archive = FixtureCorpus.bytes(FixtureCorpus.Tar.corpus),
              let members = UstarLayout.members(of: archive) else {
            Issue.record("missing or unwalkable fixture")
            return
        }

        // `@pad` appears six times, so opening it by name can only ever find the
        // first one; the distinct real members are what a round-trip means here.
        let real = members.filter { $0.name != "@pad" }
        #expect(real.count == 6)

        let staged: Void? = withStagedTarArchive(archive) { start, _ in
            withTarFileSystem { fs in
                for member in real {
                    let expected = Array(archive[member.dataOffset..<(member.dataOffset + member.size)])

                    guard case .success(let handle) = open(&fs, member.name) else {
                        Issue.record("\(member.name) did not open")
                        continue
                    }

                    #expect(fs.residentBase(handle: handle) == start + UInt64(member.dataOffset))

                    if case .success(let info) = fs.getInfo(path: member.name) {
                        #expect(info.size == member.size)
                        #expect(info.isDirectory == false)
                    } else {
                        Issue.record("\(member.name) has no info")
                    }

                    #expect(readAll(&fs, handle, upTo: member.size + 64) == expected)

                    // Rewound and read again, so the offset the first read left
                    // behind is the one `seek` is being asked to undo.
                    #expect(seek(&fs, handle, to: 0) == 0)
                    #expect(readAll(&fs, handle, upTo: member.size) == expected)

                    #expect(isSuccess(fs.close(handle: handle)))
                }
            }
        }

        #expect(staged != nil, "the guarded mapping could not be made")
    }


    @Test("a prefix, an extension and a truncation of a member name are all misses")
    func onlyExactNamesMatch() {
        guard let archive = FixtureCorpus.bytes(FixtureCorpus.Tar.corpus),
              let members = UstarLayout.members(of: archive) else {
            Issue.record("missing or unwalkable fixture")
            return
        }

        let alpha = members.first { $0.name == "alpha.txt" }?.dataOffset
        let short = members.first { $0.name == "al" }?.dataOffset

        let staged: Void? = withStagedTarArchive(archive) { start, _ in
            withTarFileSystem { fs in

                // `al` sits before `alpha.txt`, so a walk that stopped at a
                // prefix match would answer with the wrong member's data.
                if case .success(let handle) = open(&fs, "al") {
                    #expect(fs.residentBase(handle: handle) == start + UInt64(short ?? 0))
                    _ = fs.close(handle: handle)
                } else {
                    Issue.record("al did not open")
                }

                if case .success(let handle) = open(&fs, "alpha.txt") {
                    #expect(fs.residentBase(handle: handle) == start + UInt64(alpha ?? 0))
                    _ = fs.close(handle: handle)
                } else {
                    Issue.record("alpha.txt did not open")
                }

                // Prefixes of a real member, an extension of one, and a name
                // that only differs in its last byte.
                for miss in ["a", "alph", "alpha.tx", "alpha.txt.b", "alpha.txu", "beta.bi", "gamma.bin2"] {
                    #expect(isFailure(open(&fs, miss)), "\(miss) should not match any member")
                }
            }
        }

        #expect(staged != nil, "the guarded mapping could not be made")
    }


    @Test("a name that fills the whole field matches exactly and nothing shorter does")
    func fullWidthNameMatchesExactly() {
        let archive = FullWidthNameArchive.archive()
        let name    = FullWidthNameArchive.name

        #expect(name.utf8.count == 100)
        #expect(UstarLayout.matches(nameField: Array(archive[0..<100]), path: name))

        let staged: Void? = withStagedTarArchive(archive) { start, _ in
            withTarFileSystem { fs in
                guard case .success(let handle) = open(&fs, name) else {
                    Issue.record("the full-width name did not open")
                    return
                }

                #expect(fs.residentBase(handle: handle) == start + 512)
                #expect(readAll(&fs, handle, upTo: 512) == FullWidthNameArchive.contents)
                _ = fs.close(handle: handle)

                // One byte short of filling the field, and one byte longer than
                // the field can hold: neither can be the member that was found.
                #expect(isFailure(open(&fs, String(name.dropLast()))))
                #expect(isFailure(open(&fs, name + "x")))
            }
        }

        #expect(staged != nil, "the guarded mapping could not be made")
    }


    @Test("the handle table refuses the thirty-third open and recovers after a close")
    func handleTableIsBounded() {
        guard let archive = FixtureCorpus.bytes(FixtureCorpus.Tar.corpus) else {
            Issue.record("missing fixture")
            return
        }

        let staged: Void? = withStagedTarArchive(archive) { _, _ in
            withTarFileSystem { fs in
                var handles: [FileHandle] = []

                for _ in 0..<32 {
                    guard case .success(let handle) = open(&fs, "alpha.txt") else {
                        Issue.record("ran out of handles before the thirty-second")
                        return
                    }
                    handles.append(handle)
                }

                #expect(Set(handles.map(\.id)).count == 32)
                #expect(isFailure(open(&fs, "alpha.txt")))

                #expect(isSuccess(fs.close(handle: handles[7])))
                if case .success(let reused) = open(&fs, "alpha.txt") {
                    #expect(reused.id == handles[7].id)
                } else {
                    Issue.record("the freed slot was not handed back")
                }
            }
        }

        #expect(staged != nil, "the guarded mapping could not be made")
    }


    @Test("a write, append or create flag is refused before the archive is walked")
    func writableFlagsAreRefused() {
        guard let archive = FixtureCorpus.bytes(FixtureCorpus.Tar.corpus) else {
            Issue.record("missing fixture")
            return
        }

        let staged: Void? = withStagedTarArchive(archive) { _, _ in
            withTarFileSystem { fs in
                for flags in [FileFlags.write, .append, .create, [.read, .write]] as [FileFlags] {
                    let outcome = "alpha.txt".withCString { fs.open(path: $0, flags: flags) }

                    guard case .failure(let error) = outcome else {
                        Issue.record("\(flags.rawValue) was accepted")
                        continue
                    }
                    #expect(error == .readOnlyFileSystem)
                }

                // And the write path itself, which exists only to say no.
                guard case .success(let handle) = open(&fs, "alpha.txt") else { return }
                var byte: UInt8 = 0x41
                let written = withUnsafeBytes(of: &byte) { fs.write(handle: handle, buffer: $0.baseAddress!, count: 1) }
                #expect(isFailure(written))
                _ = fs.close(handle: handle)
            }
        }

        #expect(staged != nil, "the guarded mapping could not be made")
    }
}

}


// MARK: - Shared helpers

/// A `TarFileSystem` on the host heap, built the way the kernel builds it.
///
/// Heap rather than stack because the struct carries a 32-entry inline table and
/// the kernel reaches it through a pointer everywhere, so a test that took it by
/// value would be exercising a copy no kernel path ever holds. It has to be
/// constructed inside the staging: `init` records the archive base from
/// `Kernel.platformInfo` once and never re-reads it.
func withTarFileSystem<R>(_ body: (inout TarFileSystem) -> R) -> R {
    let storage = UnsafeMutablePointer<TarFileSystem>.allocate(capacity: 1)
    storage.initialize(to: TarFileSystem())
    defer {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    return body(&storage.pointee)
}


func open(_ fs: inout TarFileSystem, _ path: String) -> Result<FileHandle, FSError> {
    path.withCString { fs.open(path: $0, flags: [.read]) }
}


extension TarFileSystem {
    func getInfo(path: String) -> Result<FileInfo, FSError> {
        path.withCString { getInfo(path: $0) }
    }
}


/// Reads up to `upTo` bytes into a buffer with a poison margin behind it, and
/// returns what the filesystem said it copied.
///
/// The margin is checked before the bytes are: a `read` that ignored `count`
/// would be caught here rather than three assertions later, and the request is
/// deliberately allowed to exceed the member so the clamp is what answers.
func readAll(_ fs: inout TarFileSystem, _ handle: FileHandle, upTo count: Int) -> [UInt8]? {
    let margin = 64
    var buffer = [UInt8](repeating: 0xAA, count: count + margin)

    let outcome: Result<Size, FSError> = buffer.withUnsafeMutableBytes {
        fs.read(handle: handle, buffer: $0.baseAddress!, count: count)
    }

    guard case .success(let read) = outcome, read >= 0, read <= count else { return nil }
    guard buffer[(count)..<(count + margin)].allSatisfy({ $0 == 0xAA }) else { return nil }

    return Array(buffer[0..<read])
}


func seek(_ fs: inout TarFileSystem, _ handle: FileHandle, to offset: Int) -> Int? {
    guard case .success(let landed) = fs.seek(handle: handle, to: offset, method: .start) else {
        return nil
    }
    return landed
}


func isSuccess<T>(_ result: Result<T, FSError>) -> Bool {
    if case .success = result { return true }
    return false
}


func isFailure<T>(_ result: Result<T, FSError>) -> Bool {
    if case .failure = result { return true }
    return false
}
