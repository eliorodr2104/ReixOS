//
//  TarArchiveMutationTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import KernelTestSupport

/// Seeded mutation of the packed initrd, against a fixed oracle.
///
/// The same shape as `DeviceTreeMutationTests`: a seed in the test's own name, a
/// handful of byte edits per case printed in full on failure, and a corpus that
/// starts from an archive the project's own packer wrote rather than from random
/// bytes. What is under test is the pair of guards `TarFileSystem` relies on for
/// its safety rather than for its correctness.
///
/// ## The two guards
///
/// `isResident(base:size:)` is the clamp. A member's length is twelve octal
/// digits in a header this kernel did not author when the archive arrives by
/// `-initrd`, and a length that overruns the image would hand out a handle whose
/// data pointer names RAM the archive never covered, which `read` would copy out
/// of and `residentBase` would offer up to be mapped into a user address space.
///
/// `isFileSection` is the exact-match rule. A prefix is not a match and neither
/// is an extension, which matters because the archive holds `al` *before*
/// `alpha.txt`: a walk that stopped at a prefix would answer with the wrong
/// member's bytes, not merely with the wrong name.
///
/// ## The oracle
///
/// For every mutant and every probe path, `open` must **return**, and then
/// either fail, in which case nothing further is claimed, or hand back a handle,
/// in which case
///
/// 1. `residentBase` is non-nil, at or after the archive base, and the whole
///    declared member lies inside the archive window: the clamp held;
/// 2. the header 512 bytes before that base carries a name field that matches
///    the probe exactly, judged by `UstarLayout.matches`, which is written
///    independently of the walk it is checking;
/// 3. a `read` asking for more than the member holds returns the member's length
///    and no more, leaves a poison margin behind the buffer untouched, and copies
///    exactly the bytes the mutant has at that offset;
/// 4. `close` succeeds, so the handle table cannot leak a slot per mutant.
///
/// and throughout, enforced by the mapping rather than by an expectation: **no
/// load past the end of the archive and no store into it**. The archive is staged
/// with its last byte on the last readable byte of its window, so a walk that
/// stepped one member past the end faults, and the window is `PROT_READ`.
///
/// The staging parks the archive in `Kernel.platformInfo`, which is process-wide.
/// `.serialized` only orders this suite's own tests, so the run needs
/// `swift test --no-parallel` (see the `test` target in the Makefile).
@Suite("Tar archive mutation", .serialized)
struct TarArchiveMutationTests {

    /// Cases per seed. Each draws one to four edits and each mutant is then
    /// asked for all ten probe paths, so a seed is a few hundred mutations and
    /// well over a thousand `open` calls, for about fifteen milliseconds.
    static let casesPerSeed = 128

    /// What each mutant is asked for: every real member of the corpus, the
    /// filler the packer inserts, a prefix, an extension, and a name that is not
    /// in the archive at all.
    static let probes = [
        "alpha.txt", "al", "alpha.txt.bak", "beta.bin", "empty.dat", "gamma.bin",
        "@pad", "alpha.tx", "alpha.txt.b", "absent.bin",
    ]


    @Test("header mutants of the packed corpus, seed 0x2545F4914F6CDD1D, are refused or answered inside the archive")
    func headerMutants() {
        let tally = run(seed: 0x2545_F491_4F6C_DD1D, family: .header)

        // Some opens have to keep working and some have to start failing, or the
        // oracle is being satisfied by an archive nobody can read.
        #expect(tally.opened >= 100, tally.summary)
        #expect(tally.refused >= 50, tally.summary)
        #expect(tally.edits >= 128, tally.summary)
    }


    @Test("size-field mutants of the packed corpus, seed 0x62A9D9ED799705F5, are refused or answered inside the archive")
    func sizeFieldMutants() {
        let tally = run(seed: 0x62A9_D9ED_7997_05F5, family: .sizeField)

        // A size field is the clamp's only input, so a run that never refused an
        // open never reached the clamp.
        #expect(tally.opened >= 100, tally.summary)
        #expect(tally.refused >= 50, tally.summary)
    }


    @Test("name-field mutants of the packed corpus, seed 0x9E3779B185EBCA87, are refused or answered inside the archive")
    func nameFieldMutants() {
        let tally = run(seed: 0x9E37_79B1_85EB_CA87, family: .nameField)

        #expect(tally.opened >= 100, tally.summary)
        #expect(tally.refused >= 50, tally.summary)
    }


    // MARK: - The run

    enum Family { case header, sizeField, nameField }

    struct Tally {
        var opened  = 0
        var refused = 0
        var edits   = 0

        var summary: Comment {
            Comment(rawValue: "\(edits) edits, \(opened) opened, \(refused) refused")
        }
    }

    private func run(seed: UInt64, family: Family) -> Tally {
        var tally = Tally()

        guard let archive = FixtureCorpus.bytes(FixtureCorpus.Tar.corpus),
              let members = UstarLayout.members(of: archive) else {
            Issue.record("missing or unwalkable fixture")
            return tally
        }

        let headers = members.map(\.headerOffset)

        for mutant in plan(archive: archive, headers: headers, seed: seed, family: family) {
            tally.edits += mutant.edits.count

            let staged: Void? = withStagedTarArchive(mutant.bytes) { start, end in
                withTarFileSystem { fs in
                    for probe in Self.probes {
                        inspect(&fs, probe: probe, mutant: mutant, start: start, end: end, into: &tally)
                    }
                }
            }

            if staged == nil {
                Issue.record("the guarded mapping for \(mutant.label) could not be made")
            }
        }

        return tally
    }

    /// The mutation domain is the header blocks, never the member payloads.
    ///
    /// A flip in a member's data is invisible to the walk by construction: the
    /// bytes are copied out and compared against the same mutated array, so the
    /// case can only ever pass. Everything the filesystem decides anything from
    /// lives in the 512-byte headers.
    private func plan(
        archive: [UInt8],
        headers: [Int],
        seed   : UInt64,
        family : Family
    ) -> [Mutant] {

        makeMutants(of: archive, seed: seed, count: Self.casesPerSeed) { planner, count in
            switch family {
                case .header:
                    (0..<count).flatMap { _ in
                        let header = headers[planner.choice(headers.count)]
                        return planner.structuralEdits(in: header..<(header + 512), count: 1)
                    }

                case .sizeField:
                    (0..<count).map { _ in
                        let header = headers[planner.choice(headers.count)]
                        return octalFieldEdit(
                            at     : header + UstarLayout.sizeOffset,
                            planner: &planner
                        )
                    }

                case .nameField:
                    (0..<count).flatMap { _ in
                        let header = headers[planner.choice(headers.count)]
                        return planner.structuralEdits(
                            in   : header..<(header + UstarLayout.nameWidth),
                            count: 1
                        )
                    }
            }
        }
    }

    /// One byte of a twelve-digit octal size field, set to a digit or to
    /// something that is not a digit at all.
    ///
    /// The kernel's reader skips every byte outside `0`..`7` rather than stopping
    /// at it, so a non-digit does not truncate the number, it deletes one digit
    /// and shifts the rest: `0000010000` with its fourth byte clobbered is a
    /// different, larger size, and that is the interesting case for the clamp.
    private func octalFieldEdit(at field: Int, planner: inout MutationPlanner) -> ByteMutation {
        let digits: [UInt8] = [
            0x30, 0x31, 0x33, 0x37, 0x00, 0x20, 0x39, 0x41, 0xFF,
        ]

        return .setByte(
            offset: field + planner.choice(UstarLayout.sizeWidth),
            value : digits[planner.choice(digits.count)]
        )
    }

    private func inspect(
        _ fs  : inout TarFileSystem,
        probe : String,
        mutant: Mutant,
        start : PhysicalAddress,
        end   : PhysicalAddress,
        into tally: inout Tally
    ) {
        guard case .success(let handle) = open(&fs, probe) else {
            tally.refused += 1
            return
        }
        defer { _ = fs.close(handle: handle) }

        tally.opened += 1

        guard let base = fs.residentBase(handle: handle) else {
            Issue.record("\(mutant.label): \(probe) opened without a resident base")
            return
        }

        // The clamp. `base` is a member's data, so the header it was found
        // through is the 512 bytes before it and cannot precede the archive.
        #expect(base >= start + 512, Comment(rawValue: "\(mutant.label): \(probe)"))
        #expect(base <= end, Comment(rawValue: "\(mutant.label): \(probe)"))

        let dataOffset   = Int(base - start)
        let headerOffset = dataOffset - 512

        guard let size = UstarLayout.declaredSize(mutant.bytes, headerAt: headerOffset),
              let name = UstarLayout.nameField(mutant.bytes, headerAt: headerOffset) else {
            Issue.record("\(mutant.label): \(probe) resolved to a header outside the archive")
            return
        }

        #expect(base + UInt64(size) <= end, Comment(rawValue: "\(mutant.label): \(probe) size \(size)"))

        // The exact-match rule, judged independently of the walk that applied it.
        #expect(
            UstarLayout.matches(nameField: name, path: probe),
            Comment(rawValue: "\(mutant.label): \(probe) matched a header named \(UstarLayout.name(mutant.bytes, headerAt: headerOffset) ?? "?")")
        )

        // Asking for more than the member holds is what makes the clamp answer
        // rather than the request.
        let expected = dataOffset + size <= mutant.bytes.count
            ? Array(mutant.bytes[dataOffset..<(dataOffset + size)])
            : nil

        #expect(readAll(&fs, handle, upTo: size + 64) == expected, Comment(rawValue: "\(mutant.label): \(probe)"))
    }
}
