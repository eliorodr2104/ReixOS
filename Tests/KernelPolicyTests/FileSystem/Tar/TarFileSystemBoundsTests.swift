//
//  TarFileSystemBoundsTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 31/10/2026.


import Testing
@testable import Kernel
import KernelTestSupport

/// What `TarFileSystem` promises to a caller who asks for the wrong thing, and
/// to the walk when the archive says the wrong thing.
///
/// Offsets, counts and sizes are `UInt64` and refusals are thrown, so the
/// regressions here are the ones a type cannot rule out by itself: a position
/// past the end, a count that is enormous, a handle that is not open, a header
/// that lies. Every refusal is asserted by its error, and every case that used
/// to read before a member's data, copy a negative length, trap on an
/// addition or skip a damaged header is named for what it used to do.
///
/// Archives are staged with their last byte on the last readable byte of the
/// window and the window is read-only, exactly as in `TarArchiveCorpusTests`,
/// so an overread faults and a write faults. The run needs
/// `swift test --no-parallel` for the same reason.
extension KernelPolicyTestRoot {
@Suite("Tar file system bounds", .serialized)
struct TarFileSystemBoundsTests {

    // MARK: - Seek

    @Test("seeking to the size lands on the end and a read there returns nothing")
    func seekToSizeIsTheEnd() {
        withCorpus { fs in
            let handle = openMember(&fs, "alpha.txt")

            #expect(isSuccess(seek(&fs, handle, to: 11)))

            let (outcome, bytes) = readRaw(&fs, handle, count: 64, capacity: 64)
            #expect(outcome == .success(0))
            #expect(bytes.isEmpty)
        }
    }

    @Test("seeking one past the size is refused and leaves the position where it was")
    func seekPastSizeIsRefused() {
        withCorpus { fs in
            let handle = openMember(&fs, "alpha.txt")

            #expect(isSuccess(seek(&fs, handle, to: 3)))
            #expect(failure(of: seek(&fs, handle, to: 12)) == .invalidArgument)

            // Still at 3: the refusal did not move anything.
            #expect(readRaw(&fs, handle, count: 64, capacity: 64).bytes == Array("ha bytes".utf8))
        }
    }

    @Test("a seek to a huge or negative-looking offset is refused, never wrapped")
    func seekHugeOffsetsAreRefused() {
        withCorpus { fs in
            let handle = openMember(&fs, "alpha.txt")
            #expect(isSuccess(seek(&fs, handle, to: 2)))

            // What a negative `Int` would have been as an unsigned value, the
            // values around the 32 and 63 bit edges, and the extremes.
            let offsets: [UInt64] = [
                12, 4096, 1 << 31, 1 << 32, (1 << 32) + 2, 1 << 62, 1 << 63,
                (1 << 63) + 2, UInt64.max - 1, UInt64.max, UInt64(bitPattern: -1), UInt64(bitPattern: -12),
            ]

            for offset in offsets {
                #expect(
                    failure(of: seek(&fs, handle, to: offset)) == .invalidArgument,
                    Comment(rawValue: "offset \(offset)")
                )
            }

            // Not one of them moved the position: this used to be reachable by
            // seeking from the end with a negative offset, which sent a read
            // to bytes before the member.
            #expect(readRaw(&fs, handle, count: 64, capacity: 64).bytes == Array("pha bytes".utf8))
        }
    }

    @Test("an empty member can be sought to 0 and no further")
    func seekOnEmptyMember() {
        withCorpus { fs in
            let handle = openMember(&fs, "empty.dat")

            #expect(isSuccess(seek(&fs, handle, to: 0)))
            #expect(failure(of: seek(&fs, handle, to: 1)) == .invalidArgument)
            #expect(failure(of: seek(&fs, handle, to: UInt64.max)) == .invalidArgument)
            #expect(readRaw(&fs, handle, count: 8, capacity: 8).outcome == .success(0))
            #expect(sizeOf(&fs, handle) == .success(0))
        }
    }

    @Test("every offset from 0 to the size can be sought to and reads the tail from there")
    func seekEveryOffsetOfAMember() {
        withCorpus { fs in
            let handle = openMember(&fs, "alpha.txt")
            let member = Array("alpha bytes".utf8)

            for offset in 0...member.count {
                #expect(isSuccess(seek(&fs, handle, to: UInt64(offset))))
                #expect(
                    readRaw(&fs, handle, count: 64, capacity: 64).bytes == Array(member[offset...]),
                    Comment(rawValue: "offset \(offset)")
                )
            }
        }
    }


    // MARK: - Read

    @Test("a read of nothing returns nothing and does not move the position")
    func readOfZeroBytes() {
        withCorpus { fs in
            let handle = openMember(&fs, "alpha.txt")

            #expect(readRaw(&fs, handle, count: 0, capacity: 8).outcome == .success(0))
            #expect(readRaw(&fs, handle, count: 64, capacity: 64).bytes == Array("alpha bytes".utf8))
        }
    }

    @Test("a read of an enormous count is clamped to what is left, with no overflow")
    func readOfEnormousCountIsClamped() {
        // `currentOffset + count` used to be formed before the clamp, so any
        // count near the top of the range trapped, which is a kernel panic.
        for count in [UInt64(1) << 31, 1 << 32, 1 << 62, 1 << 63, UInt64.max - 11, UInt64.max - 1, UInt64.max] {
            withCorpus { fs in
                let handle = openMember(&fs, "alpha.txt")

                // Moved off zero so offset and count both feed the sum.
                #expect(isSuccess(seek(&fs, handle, to: 4)))

                let (outcome, bytes) = readRaw(&fs, handle, count: count, capacity: 7)
                #expect(outcome == .success(7), Comment(rawValue: "count \(count)"))
                #expect(bytes == Array("a bytes".utf8), Comment(rawValue: "count \(count)"))
            }
        }
    }

    @Test("a read of exactly what is left, one less and one more all answer by the member")
    func readAroundTheRemainder() {
        withCorpus { fs in
            let handle = openMember(&fs, "alpha.txt")
            let member = Array("alpha bytes".utf8)

            for (count, expected) in [(UInt64(11), 11), (10, 10), (12, 11), (100, 11)] {
                #expect(isSuccess(seek(&fs, handle, to: 0)))
                let bytes = readRaw(&fs, handle, count: count, capacity: Int(count) + 8).bytes
                #expect(bytes == Array(member[0..<expected]), Comment(rawValue: "count \(count)"))
            }

            // One short, then the last byte, then nothing.
            #expect(isSuccess(seek(&fs, handle, to: 0)))
            #expect(readRaw(&fs, handle, count: 10, capacity: 10).bytes == Array(member[0..<10]))
            #expect(readRaw(&fs, handle, count: 10, capacity: 10).bytes == Array(member[10...]))
            #expect(readRaw(&fs, handle, count: 10, capacity: 10).outcome == .success(0))
        }
    }

    @Test("reading a member in chunks yields it once and then end of file")
    func readInChunksCoversTheMember() {
        guard let archive = FixtureCorpus.bytes(FixtureCorpus.Tar.corpus),
              let beta = UstarLayout.members(of: archive)?.first(where: { $0.name == "beta.bin" })
        else {
            Issue.record("missing fixture")
            return
        }

        let expected = Array(archive[beta.dataOffset..<(beta.dataOffset + beta.size)])

        withCorpus { fs in
            let handle = openMember(&fs, "beta.bin")

            // Bounded, so a read that stops advancing fails instead of spinning.
            var collected: [UInt8] = []
            for _ in 0..<8 {
                let (outcome, bytes) = readRaw(&fs, handle, count: 1000, capacity: 1000)
                guard case .success(let count) = outcome else {
                    Issue.record("a read failed")
                    return
                }
                if count == 0 { break }

                collected += bytes
            }

            #expect(collected == expected)
            #expect(readRaw(&fs, handle, count: 1, capacity: 1).outcome == .success(0))
        }
    }

    @Test("a member that ends on the last byte of the archive reads to the last byte and no further")
    func memberEndingAtTheEndOfTheArchive() {
        let data    = (0..<37).map { UInt8($0 &* 7 &+ 1) }
        let archive = member("tail.bin", data: data, padded: false)

        staged(archive) { fs in
            let handle = openMember(&fs, "tail.bin")

            #expect(sizeOf(&fs, handle) == .success(37))
            #expect(readRaw(&fs, handle, count: UInt64.max, capacity: 37).bytes == data)
            #expect(readRaw(&fs, handle, count: 1, capacity: 1).outcome == .success(0))
        }
    }


    // MARK: - Size

    @Test("the size of an open member is the size its header declares")
    func sizeOfOpenMembers() {
        withCorpus { fs in
            for (name, size) in [("empty.dat", UInt64(0)), ("alpha.txt", 11), ("gamma.bin", 600), ("beta.bin", 4096)] {
                let handle = openMember(&fs, name)
                #expect(sizeOf(&fs, handle) == .success(size), Comment(rawValue: name))
            }
        }
    }

    @Test("size, like getInfo, answers for a member without opening it")
    func getInfoSizesAgree() {
        withCorpus { fs in
            for (name, size) in [("empty.dat", UInt64(0)), ("alpha.txt", 11), ("gamma.bin", 600), ("beta.bin", 4096)] {
                guard case .success(let info) = fs.getInfo(path: name) else {
                    Issue.record("\(name) has no info")
                    continue
                }

                #expect(info.size == size)
                #expect(info.isDirectory == false)
                #expect(info.permissions == 0)
            }

            #expect(failure(of: fs.getInfo(path: "absent.bin")) == .fileNotFound)
        }
    }


    // MARK: - Handles

    @Test("a handle outside the table is refused by every operation")
    func handleOutsideTheTable() {
        withCorpus { fs in
            _ = openMember(&fs, "alpha.txt")

            for id in [-1, 32, 33, 1000, Int.max, Int.min] {
                let handle = FileHandle(id: id)
                let label  = Comment(rawValue: "id \(id)")

                #expect(failure(of: readRaw(&fs, handle, count: 4, capacity: 4).outcome) == .invalidArgument, label)
                #expect(failure(of: seek(&fs, handle, to: 0)) == .invalidArgument, label)
                #expect(failure(of: sizeOf(&fs, handle)) == .invalidArgument, label)
                #expect(failure(of: close(&fs, handle)) == .invalidArgument, label)
                #expect(fs.residentBase(handle: handle) == nil, label)
            }
        }
    }

    @Test("a slot that was never opened is refused by every operation")
    func handleNeverOpened() {
        withCorpus { fs in
            for id in 0..<32 {
                let handle = FileHandle(id: id)
                let label  = Comment(rawValue: "id \(id)")

                #expect(failure(of: readRaw(&fs, handle, count: 4, capacity: 4).outcome) == .ioError, label)
                #expect(failure(of: seek(&fs, handle, to: 0)) == .ioError, label)
                #expect(failure(of: sizeOf(&fs, handle)) == .ioError, label)
                #expect(failure(of: close(&fs, handle)) == .ioError, label)
                #expect(fs.residentBase(handle: handle) == nil, label)
            }
        }
    }

    @Test("a second close is refused and a closed handle is dead for everything else")
    func closeTwice() {
        withCorpus { fs in
            let first  = openMember(&fs, "alpha.txt")
            let second = openMember(&fs, "gamma.bin")

            #expect(isSuccess(close(&fs, first)))

            // The slot is free now, so closing it again used to succeed and
            // would have closed whatever opened into it next.
            #expect(failure(of: close(&fs, first)) == .ioError)
            #expect(failure(of: readRaw(&fs, first, count: 4, capacity: 4).outcome) == .ioError)
            #expect(failure(of: seek(&fs, first, to: 0)) == .ioError)
            #expect(failure(of: sizeOf(&fs, first)) == .ioError)
            #expect(fs.residentBase(handle: first) == nil)

            // The other handle did not notice.
            #expect(sizeOf(&fs, second) == .success(600))
            #expect(isSuccess(close(&fs, second)))
        }
    }


    // MARK: - Damaged headers

    @Test("a header whose checksum does not hold is not a member, found or walked over")
    func checksumMismatchRefusesTheMember() {
        var damaged = member("alpha.txt", data: Array("alpha bytes".utf8), edit: { $0[100] = 0x31 }, sealed: false)
        damaged += member("beta.bin", data: [1, 2, 3])

        staged(archive(of: [damaged])) { fs in
            // The target itself, and a member that can only be reached by
            // stepping over it by a size nobody vouched for.
            #expect(failure(of: open(&fs, "alpha.txt")) == .ioError)
            #expect(failure(of: fs.getInfo(path: "alpha.txt")) == .ioError)
            #expect(failure(of: open(&fs, "beta.bin")) == .ioError)
        }

        // The same bytes with the checksum redone are a member again.
        var repaired = member("alpha.txt", data: Array("alpha bytes".utf8), edit: { $0[100] = 0x31 })
        repaired += member("beta.bin", data: [1, 2, 3])

        staged(archive(of: [repaired])) { fs in
            #expect(isSuccess(open(&fs, "alpha.txt")))
            #expect(isSuccess(open(&fs, "beta.bin")))
        }
    }

    @Test("no single bit flipped in a member's header can leave it openable")
    func everyBitOfTheTargetHeaderIsCovered() {
        let data = Array("sixteen bytes!!!".utf8)

        // The checksum field's last byte is NUL or space, both padding, and
        // bit 5 turns one into the other without changing the number.
        let paddingSwap: Set<[Int]> = [[154, 5], [155, 5]]

        for index in 0..<512 {
            for bit in 0..<8 {
                var damaged = member("probe.bin", data: data, edit: { $0[index] ^= (1 << UInt8(bit)) }, sealed: false)
                damaged += zeros(1024)

                staged(damaged) { fs in
                    let opened = isSuccess(open(&fs, "probe.bin"))

                    #expect(
                        opened == paddingSwap.contains([index, bit]),
                        Comment(rawValue: "bit \(bit) of header byte \(index)")
                    )
                }
            }
        }
    }

    @Test("a damaged header after the target does not matter, the walk never reaches it")
    func damageAfterTheTargetIsNotWalked() {
        var bytes = member("first.bin", data: [1, 2, 3, 4])
        bytes += member("second.bin", data: [5], edit: { $0[100] = 0x31 }, sealed: false)

        staged(archive(of: [bytes])) { fs in
            #expect(isSuccess(open(&fs, "first.bin")))
            #expect(failure(of: open(&fs, "second.bin")) == .ioError)
        }
    }

    @Test("a header without the ustar magic ends the walk as not found, even with a good checksum")
    func missingMagicIsNotFound() {
        let bytes = member("odd.bin", data: [1], edit: { $0[257] = UInt8(ascii: "X") })

        staged(archive(of: [bytes])) { fs in
            #expect(failure(of: open(&fs, "odd.bin")) == .fileNotFound)
        }
    }

    @Test("an archive with nothing in it has no members")
    func emptyArchive() {
        staged(zeros(1024)) { fs in
            #expect(failure(of: open(&fs, "alpha.txt")) == .fileNotFound)
            #expect(failure(of: fs.getInfo(path: "alpha.txt")) == .fileNotFound)
        }
    }


    // MARK: - Size fields

    @Test("a size field that is not octal digits then padding refuses the member")
    func malformedSizeFieldRefusesTheMember() {
        // Each of these, with a checksum that holds, used to be read by
        // skipping the bytes that were not digits: the first as 7, the last as
        // a size of zero.
        let fields: [[UInt8]] = [
            Array("0000000000A7".utf8),
            Array("00000000008\0".utf8),
            Array("00000000009\0".utf8),
            Array("-0000000007\0".utf8),
            Array("+0000000007\0".utf8),
            Array(" 0000000007\0".utf8),
            Array("000000007\0 7".utf8),
            Array("0000007\0\0\0\0".utf8) + [0x37],
            Array("00000000x07\0".utf8),
            [0xFF, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0],
            [0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x37, 0x80],
            [UInt8](repeating: 0x20, count: 12),
            [UInt8](repeating: 0, count: 12),
        ]

        for field in fields {
            #expect(field.count == 12, Comment(rawValue: "\(field)"))

            let bytes = member("probe.bin", data: [1, 2, 3, 4, 5, 6, 7], edit: { $0.replaceSubrange(124..<136, with: field) })

            staged(archive(of: [bytes])) { fs in
                #expect(failure(of: open(&fs, "probe.bin")) == .ioError, Comment(rawValue: "\(field)"))
                #expect(failure(of: fs.getInfo(path: "probe.bin")) == .ioError, Comment(rawValue: "\(field)"))
            }
        }
    }

    @Test("a malformed size field also stops the walk to the members behind it")
    func malformedSizeFieldStopsTheWalk() {
        let bad  = member("bad.bin", data: [1], edit: { $0.replaceSubrange(124..<136, with: Array("0000000000A1".utf8)) })
        let good = member("good.bin", data: [2])

        staged(archive(of: [bad + good])) { fs in
            #expect(failure(of: open(&fs, "good.bin")) == .ioError)
        }
    }

    @Test("the three ways of writing a size that are valid all open")
    func validSizeSpellingsOpen() {
        for field in ["00000000007\0", "00000000007 ", "000000000007"] {
            let bytes = member("probe.bin", data: [1, 2, 3, 4, 5, 6, 7], edit: { $0.replaceSubrange(124..<136, with: Array(field.utf8)) })

            staged(archive(of: [bytes])) { fs in
                let handle = openMember(&fs, "probe.bin")
                #expect(sizeOf(&fs, handle) == .success(7), Comment(rawValue: field))
            }
        }
    }

    @Test("a size that runs one byte past the archive is refused, one that fits exactly is not")
    func sizeAgainstTheEndOfTheArchive() {
        let data = [UInt8](repeating: 0x5A, count: 40)

        // Data ends on the last byte of the window: the largest size that fits.
        staged(member("edge.bin", data: data, padded: false)) { fs in
            #expect(isSuccess(open(&fs, "edge.bin")))
            #expect(sizeOf(&fs, openMember(&fs, "edge.bin")) == .success(40))
        }

        let overrun = member("edge.bin", data: data, edit: { $0.replaceSubrange(124..<136, with: Array("00000000051\0".utf8)) }, padded: false)

        staged(overrun) { fs in
            #expect(failure(of: open(&fs, "edge.bin")) == .ioError)
            #expect(failure(of: fs.getInfo(path: "edge.bin")) == .ioError)
        }
    }

    @Test("the largest sizes the field can hold are refused without a trap or a walk")
    func hugeSizesAreRefused() {
        for field in ["77777777777\0", "777777777777"] {
            let target = member("huge.bin", data: [1], edit: { $0.replaceSubrange(124..<136, with: Array(field.utf8)) })

            staged(archive(of: [target])) { fs in
                #expect(failure(of: open(&fs, "huge.bin")) == .ioError, Comment(rawValue: field))
                #expect(failure(of: fs.getInfo(path: "huge.bin")) == .ioError, Comment(rawValue: field))
            }

            // Walked over rather than asked for, the member's size sends the
            // next header far outside the window, which is the end of the walk.
            let skipped = target + member("after.bin", data: [2])

            staged(archive(of: [skipped])) { fs in
                #expect(failure(of: open(&fs, "after.bin")) == .fileNotFound, Comment(rawValue: field))
            }
        }
    }

    @Test("the walk steps over a member by its size rounded up to whole blocks")
    func sizesStepTheWalkByWholeBlocks() {
        // A member of 512 bytes ends on a block, one of 513 spills into a second.
        for length in [0, 1, 511, 512, 513, 1024] {
            let bytes = member("first.bin", data: [UInt8](repeating: 1, count: length))
                + member("second.bin", data: [9, 9])

            staged(archive(of: [bytes])) { fs in
                let handle = openMember(&fs, "second.bin")
                #expect(readRaw(&fs, handle, count: 8, capacity: 8).bytes == [9, 9], Comment(rawValue: "after \(length)"))
            }
        }
    }


    // MARK: - Staging

    /// The packed corpus, staged, with a filesystem over it.
    private func withCorpus(_ body: (inout TarFileSystem) -> Void) {
        guard let archive = FixtureCorpus.bytes(FixtureCorpus.Tar.corpus) else {
            Issue.record("missing fixture")
            return
        }

        staged(archive) { fs in body(&fs) }
    }

    private func staged(_ archive: [UInt8], _ body: (inout TarFileSystem) -> Void) {
        let ran: Void? = withStagedTarArchive(archive) { _, _ in
            withTarFileSystem { fs in body(&fs) }
        }

        #expect(ran != nil, "the guarded mapping could not be made")
    }

    private func openMember(_ fs: inout TarFileSystem, _ name: String) -> FileHandle {
        guard case .success(let handle) = open(&fs, name) else {
            Issue.record("\(name) did not open")
            return FileHandle(id: -1)
        }
        return handle
    }

    private func sizeOf(_ fs: inout TarFileSystem, _ handle: FileHandle) -> Result<UInt64, FSError> {
        Result { () throws(FSError) in try fs.size(handle: handle) }
    }

    private func failure<T>(of result: Result<T, FSError>) -> FSError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    /// A read into a buffer of `capacity` bytes with a poison margin behind it.
    /// `bytes` is what the call said it copied, empty when it failed, and a
    /// write past that count is an issue here rather than a silent corruption.
    private func readRaw(
        _ fs     : inout TarFileSystem,
        _ handle : FileHandle,
        count    : UInt64,
        capacity : Int
    ) -> (outcome: Result<UInt64, FSError>, bytes: [UInt8]) {

        let margin = 64
        var buffer = [UInt8](repeating: 0xAA, count: capacity + margin)

        let outcome: Result<UInt64, FSError> = buffer.withUnsafeMutableBytes { raw in
            Result { () throws(FSError) in
                try fs.read(handle: handle, buffer: raw.baseAddress!, count: count)
            }
        }

        guard case .success(let read) = outcome else { return (outcome, []) }

        #expect(read <= UInt64(capacity), "read more than the buffer holds")
        #expect(
            buffer[Int(min(read, UInt64(capacity)))...].allSatisfy { $0 == 0xAA },
            "read wrote past the bytes it reported"
        )

        return (outcome, Array(buffer[0..<Int(min(read, UInt64(capacity)))]))
    }


    // MARK: - Archive building

    private func zeros(_ count: Int) -> [UInt8] { [UInt8](repeating: 0, count: count) }

    /// One member: a header the `edit` may change, sealed afterwards unless the
    /// test wants the checksum wrong, then the data, padded to a block unless
    /// the test wants it to end on the last byte of the archive.
    private func member(
        _ name  : String,
        data    : [UInt8],
        edit    : (inout [UInt8]) -> Void = { _ in },
        sealed  : Bool = true,
        padded  : Bool = true
    ) -> [UInt8] {

        var header = ustarHeader(name: Array(name.utf8), size: data.count)
        edit(&header)
        if sealed { sealUstarHeader(&header, at: 0) }

        return header + data + (padded ? zeros((512 - data.count % 512) % 512) : [])
    }

    private func archive(of members: [[UInt8]]) -> [UInt8] {
        members.flatMap { $0 } + zeros(1024)
    }
}

}
