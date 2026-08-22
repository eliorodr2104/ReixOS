//
//  DeviceTreeMutationTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import KernelTestSupport

/// Seeded mutation of a real device tree, against a fixed oracle.
///
/// Not a fuzzer in the sense of a long-running campaign: every case is derived
/// from one `UInt64` in the test's own name, the plan is a handful of byte edits
/// printed in full when an expectation fails, and the whole suite is a few
/// hundred parses. The value is that the edits are drawn from bytes QEMU
/// actually emitted, so a case is a plausible corruption of a real tree rather
/// than a random buffer that dies at the magic.
///
/// ## The oracle
///
/// For every mutant `getPlatformInfo` must **return**, and then either
///
/// 1. hand back a `DeviceTreeFault`, in which case the only further claim is the
///    fault type's own contract: a reason about the blob as a whole carries no
///    offset, and every reason about a place in it carries one; or
/// 2. hand back nothing, in which case the `PlatformInfo` has to satisfy what
///    the walk guarantees: `dtbBase` is the blob as staged and `dtbSize` is what
///    the blob declares, the console has a non-zero base (the `missingConsole`
///    gate), the UART's INTID is below the first reserved one, `bootargs` (the
///    only pointer into the blob the kernel keeps) lands inside the declared
///    extent, the CPU count is under what the declared extent could hold, and
///    both blocks lie inside the declared size without overlapping, which is the
///    header guard restated in the blob's own arithmetic.
///
/// and in both cases, enforced by the mapping rather than by an expectation:
/// **no load outside the declared blob and no store into it at all**. The blob
/// is staged in a window sized to what its own header declares, with an
/// unreadable page on each side and `PROT_READ` on the blob, so either violation
/// is a fault that takes the test process down. That is the point: an
/// out-of-bounds read is not something a host assertion can observe after the
/// fact.
///
/// ## What the oracle deliberately does not claim
///
/// Nothing about the *contents* of the cells the walk copies out. `ram`, and the
/// initrd window `/chosen` declares, are 64-bit values read verbatim from a blob
/// the kernel treats as trusted firmware input, and the walk does not check
/// either against the other: a flip in the strings block that renames
/// `linux,initrd-start` leaves `initrdStart` at zero with `initrdEnd` still set,
/// and the blob is accepted. That is a real hardening gap rather than a broken
/// expectation, so it is not asserted here; the values the real captures produce
/// are pinned in `DeviceTreeCorpusTests` instead, where they are facts about the
/// machine rather than about the parser.
///
/// ## What is mutated, and what is not
///
/// The domain is the *live* extent: the header plus the struct and strings
/// blocks, roughly 7.5 KiB of the 1 MiB the blob declares. The rest is the
/// padding QEMU leaves behind `FDT_END`, which no parser reads, so an edit there
/// is a case that cannot fail and spending the budget on those is how a corpus
/// ends up green for the wrong reason.
///
/// Structural edits and header length-field edits are drawn as separate
/// families, never mixed in one case. A header that grows the struct block plus
/// a flip that removes `FDT_END` would turn a bounded walk into a
/// multi-million-iteration one, and the case that found a bug would stop being
/// the case that is cheap to explain.
///
/// This suite owns no kernel global: `getPlatformInfo` fills a caller's
/// `PlatformInfo`. It runs under `swift test --no-parallel` with the rest all
/// the same.
@Suite("Device tree mutation")
struct DeviceTreeMutationTests {

    /// Cases per seed. Each draws one to four edits, so a seed is between one
    /// and four hundred mutations, and a seed costs a few milliseconds.
    static let casesPerSeed = 96

    /// Reasons that describe the blob rather than a place in it, and therefore
    /// arrive without an offset. The other side of `DeviceTreeFault.offset`
    /// being optional rather than zero.
    static let positionlessReasons: Set<String> = [
        "missingBlob", "misalignedBlob", "badMagic", "shortHeader", "missingConsole",
    ]


    @Test("structural mutants of the 128M capture, seed 0x9E3779B97F4A7C15, are refused or reported inside the blob")
    func structuralMutantsOf128M() {
        let tally = run(
            fixture: FixtureCorpus.DeviceTree.virt128M,
            seed   : 0x9E37_79B9_7F4A_7C15,
            family : .structural
        )

        // A run where nothing parsed, or where every case died at one guard, would
        // satisfy the oracle while testing one branch. Floors, not equalities.
        #expect(tally.faults.count >= 4, tally.summary)
        #expect(tally.parsed >= 1, tally.summary)
        #expect(tally.edits >= 96, tally.summary)
    }


    @Test("structural mutants of the initrd capture, seed 0xB5026F5AA96619E9, are refused or reported inside the blob")
    func structuralMutantsOfInitrdCapture() {
        let tally = run(
            fixture: FixtureCorpus.DeviceTree.virt128MInitrd,
            seed   : 0xB502_6F5A_A966_19E9,
            family : .structural
        )

        #expect(tally.faults.count >= 3, tally.summary)
        #expect(tally.parsed >= 1, tally.summary)
    }


    @Test("length-field mutants of the 128M capture, seed 0xD1B54A32D192ED03, are refused or reported inside the blob")
    func lengthFieldMutantsOf128M() {
        let tally = run(
            fixture: FixtureCorpus.DeviceTree.virt128M,
            seed   : 0xD1B5_4A32_D192_ED03,
            family : .lengthField
        )

        // Every one of these edits rewrites a bound the walk works to, so the
        // header guards are what should be answering.
        #expect(tally.faults.count >= 8, tally.summary)
        #expect(tally.faults["structBlockBounds", default: 0] >= 1, tally.summary)
        #expect(tally.faults["stringBlockBounds", default: 0] >= 1, tally.summary)
    }


    @Test("the same seed plans the same mutations twice")
    func seedsAreReproducible() {
        guard let blob = FixtureCorpus.bytes(FixtureCorpus.DeviceTree.virt128M) else {
            Issue.record("missing fixture")
            return
        }

        let first  = plan(blob: blob, seed: 0x9E37_79B9_7F4A_7C15, family: .structural)
        let second = plan(blob: blob, seed: 0x9E37_79B9_7F4A_7C15, family: .structural)
        let other  = plan(blob: blob, seed: 0x9E37_79B9_7F4A_7C16, family: .structural)

        #expect(first.map(\.label) == second.map(\.label))

        // The labels decide the bytes, so comparing every megabyte twice would
        // only re-test `ByteMutation.apply`. Three spot checks keep it honest.
        for index in [0, Self.casesPerSeed / 2, Self.casesPerSeed - 1] {
            #expect(first[index].bytes == second[index].bytes)
        }

        // And a neighbouring seed does not produce the same plan, which is what
        // makes the seed in the test name worth writing down.
        #expect(first.map(\.label) != other.map(\.label))
    }


    // MARK: - The run

    enum Family { case structural, lengthField }

    /// What a seed's run observed, for the coverage expectations and for the
    /// message a failure prints.
    struct Tally {
        var parsed = 0
        var edits  = 0
        var faults: [String: Int] = [:]

        var summary: Comment {
            let reasons = faults.sorted { $0.key < $1.key }
                                .map { "\($0.key) \($0.value)" }
                                .joined(separator: ", ")
            return Comment(rawValue: "\(edits) edits, \(parsed) parsed, faults: [\(reasons)]")
        }
    }

    private func plan(blob: [UInt8], seed: UInt64, family: Family) -> [Mutant] {
        let live = DeviceTreeBlob.liveExtent(blob)

        return makeMutants(of: blob, seed: seed, count: Self.casesPerSeed) { planner, count in
            switch family {
                case .structural:
                    planner.structuralEdits(in: live, count: count)

                case .lengthField:
                    planner.lengthFieldEdits(
                        at     : DeviceTreeBlob.lengthFields,
                        current: { DeviceTreeBlob.word(blob, at: $0) },
                        count  : count
                    )
            }
        }
    }

    private func run(fixture: String, seed: UInt64, family: Family) -> Tally {
        var tally = Tally()

        guard let blob = FixtureCorpus.bytes(fixture) else {
            Issue.record("missing fixture \(fixture)")
            return tally
        }

        for mutant in plan(blob: blob, seed: seed, family: family) {
            tally.edits += mutant.edits.count

            let staged: Void? = withStagedDeviceTree(mutant.bytes) { base in
                inspect(mutant, at: base, into: &tally)
            }

            if staged == nil {
                Issue.record("the guarded mapping for \(mutant.label) could not be made")
            }
        }

        return tally
    }

    private func inspect(_ mutant: Mutant, at base: UnsafeRawPointer, into tally: inout Tally) {
        var info  = PlatformInfo()
        let fault = getPlatformInfo(&info, at: base)

        if let fault {
            let reason = String(describing: fault.reason)
            tally.faults[reason, default: 0] += 1

            #expect(
                (fault.offset == nil) == Self.positionlessReasons.contains(reason),
                "\(mutant.label): \(reason) reported offset \(String(describing: fault.offset))"
            )
            return
        }

        tally.parsed += 1

        let declared = DeviceTreeBlob.declaredReach(mutant.bytes)
        let start    = UInt64(UInt(bitPattern: base))

        #expect(info.dtbBase == start, Comment(rawValue: mutant.label))
        #expect(info.dtbSize == DeviceTreeBlob.totalSize(mutant.bytes), Comment(rawValue: mutant.label))
        #expect(info.uart.baseAddr != 0, Comment(rawValue: mutant.label))
        #expect(info.uart.irq < 1020, Comment(rawValue: mutant.label))

        // A counted CPU costs at least a tag and a padded `cpu@x` name, so the
        // declared extent bounds how many of them there can be.
        #expect(info.cpuCount <= UInt32(declared / 12) + 1, Comment(rawValue: mutant.label))

        // The only pointer into the blob the kernel keeps and later dereferences.
        if let bootargs = info.bootargs {
            let address = UInt64(UInt(bitPattern: bootargs))
            #expect(address >= start && address < start + UInt64(declared), Comment(rawValue: mutant.label))
        }

        // The header guards from outside the walk: an accepted blob has both
        // blocks inside the size it declares, and they do not overlap.
        let total      = UInt64(DeviceTreeBlob.totalSize(mutant.bytes))
        let structOff  = UInt64(DeviceTreeBlob.word(mutant.bytes, at: 8))
        let structEnd  = structOff + UInt64(DeviceTreeBlob.word(mutant.bytes, at: 36))
        let stringsOff = UInt64(DeviceTreeBlob.word(mutant.bytes, at: 12))
        let stringsEnd = stringsOff + UInt64(DeviceTreeBlob.word(mutant.bytes, at: 32))

        #expect(structEnd  <= total, Comment(rawValue: mutant.label))
        #expect(stringsEnd <= total, Comment(rawValue: mutant.label))
        #expect(structEnd <= stringsOff || stringsEnd <= structOff, Comment(rawValue: mutant.label))
    }
}
