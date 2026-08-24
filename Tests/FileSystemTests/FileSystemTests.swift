//
//  FileSystemTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// The file system, on a disk made of memory.
///
/// Every one of these would need a machine, a driver and a queue to run if the
/// file system had been written against a disk instead of against `BlockDevice`.
/// It was not, so they run in milliseconds and can afford to be thorough.
@Suite("File system")
struct FileSystemTests {

    /// 16 MiB, the same as the image the Makefile makes.
    private static let sectors: UInt64 = 32768


    /// A formatted file system on a fresh disk, and the scratch it needs.
    private func withFileSystem(
        sectors: UInt64 = FileSystemTests.sectors,
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void
    ) {
        let disk = MemoryDisk(sectors: sectors)

        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes,
            alignment: 8
        )
        defer { scratch.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: scratch).disk else {
            Issue.record("a fresh disk could not be formatted")
            return
        }

        body(&fs, disk)
    }


    private func name(_ text: StaticString, _ body: (UnsafeRawPointer, Int) -> Void) {
        body(UnsafeRawPointer(text.utf8Start), text.utf8CodeUnitCount)
    }


    @discardableResult
    private func create(
        _ fs: inout FileSystem<MemoryDisk>,
        _ text: StaticString,
        kind: FSKind = .file,
        in folder: UInt32 = FSLayout.rootObject
    ) -> UInt32? {
        var made: UInt32? = nil
        name(text) { pointer, length in
            let result = fs.create(pointer, length: length, kind: kind, in: folder)
            if result.status == .ok { made = result.object }
        }
        return made
    }


    private func find(
        _ fs: inout FileSystem<MemoryDisk>,
        _ text: StaticString,
        in folder: UInt32 = FSLayout.rootObject
    ) -> UInt32? {
        var found: UInt32? = nil
        name(text) { pointer, length in found = fs.lookup(pointer, length: length, in: folder) }
        return found
    }


    private func remove(
        _ fs: inout FileSystem<MemoryDisk>,
        _ text: StaticString,
        from folder: UInt32 = FSLayout.rootObject
    ) -> FSStatus {
        var status = FSStatus.notFound
        name(text) { pointer, length in
            status = fs.remove(pointer, length: length, from: folder)
        }
        return status
    }


    // MARK: - The disk itself

    @Test("a fresh disk gets a root, and mounting again finds the same one")
    func formatThenMount() {
        let disk = MemoryDisk(sectors: Self.sectors)
        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
        defer { scratch.deallocate() }

        guard var first = FileSystem.format(disk, scratch: scratch).disk else {
            Issue.record("the disk would not format")
            return
        }

        #expect(first.wasDirty == false)
        create(&first, "hello.txt")
        #expect(first.unmount() == .ok)

        guard var again = FileSystem.mount(disk, scratch: scratch).disk else {
            Issue.record("a formatted disk would not mount")
            return
        }

        // Not reformatted: the file is still there.
        #expect(again.wasDirty == false)
        #expect(find(&again, "hello.txt") != nil)
    }


    @Test("a disk that was never unmounted says so, and keeps its contents")
    func dirtyIsReported() {
        let disk = MemoryDisk(sectors: Self.sectors)
        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
        defer { scratch.deallocate() }

        guard var first = FileSystem.format(disk, scratch: scratch).disk else {
            Issue.record("the disk would not format")
            return
        }
        create(&first, "a.txt")
        // No unmount: the mark stays set, which is what a power cut looks like.

        guard var again = FileSystem.mount(disk, scratch: scratch).disk else {
            Issue.record("a dirty disk would not mount")
            return
        }

        #expect(again.wasDirty)
        #expect(find(&again, "a.txt") != nil)
    }


    @Test("a disk too small to hold a file system is refused, not half made")
    func tinyDiskIsRefused() {
        let disk = MemoryDisk(sectors: 8)   // one block
        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
        defer { scratch.deallocate() }

        // Neither door: a device this format does not fit is refused by
        // both, and `unusable` says which of the refusals it is.
        let attempt = FileSystem.mount(disk, scratch: scratch)

        #expect(attempt.disk == nil)
        #expect(isUnusable(attempt.found))
        #expect(FileSystem.format(disk, scratch: scratch).disk == nil)
        #expect(disk.writes == 0)
    }


    // MARK: - Names

    @Test("a name that was created is found, and one that was not is not")
    func createAndLookup() {
        withFileSystem { fs, _ in
            let made = create(&fs, "notes.txt")
            #expect(made != nil)
            #expect(find(&fs, "notes.txt") == made)
            #expect(find(&fs, "other.txt") == nil)
        }
    }


    @Test("the same name twice is refused the second time")
    func duplicateIsRefused() {
        withFileSystem { fs, _ in
            #expect(create(&fs, "twice.txt") != nil)

            name("twice.txt") { pointer, length in
                let again = fs.create(pointer, length: length, kind: .file, in: FSLayout.rootObject)
                #expect(again.status == .exists)
            }
        }
    }


    @Test("a name a folder may not hold is refused")
    func badNamesAreRefused() {
        withFileSystem { fs, _ in
            for text in ["a/b", "a:b", "a b", ""] {
                let status = text.withCString { raw -> FSStatus in
                    raw.withMemoryRebound(to: UInt8.self, capacity: text.count) { bytes in
                        fs.create(
                            UnsafeRawPointer(bytes),
                            length: text.count,
                            kind  : .file,
                            in    : FSLayout.rootObject
                        ).status
                    }
                }
                #expect(status == .badName || status == .wrongKind)
            }
        }
    }


    @Test("a folder holds its own names, and the root does not see them")
    func foldersAreSeparate() {
        withFileSystem { fs, _ in
            guard let folder = create(&fs, "docs", kind: .folder) else {
                Issue.record("the folder was not created")
                return
            }

            #expect(create(&fs, "inside.txt", in: folder) != nil)
            #expect(find(&fs, "inside.txt", in: folder) != nil)
            #expect(find(&fs, "inside.txt") == nil)

            // The same name may exist in both, naming different things.
            #expect(create(&fs, "inside.txt") != nil)
            #expect(find(&fs, "inside.txt") != find(&fs, "inside.txt", in: folder))
        }
    }


    @Test("more names than one block holds still all come back")
    func aFolderGrows() {
        withFileSystem { fs, _ in
            // 64 entries fit in a block; 200 needs four of them.
            var made = 0
            for index in 0..<200 {
                var text = InlineArray<8, UInt8>(repeating: 0)
                text[0] = UInt8(ascii: "f")
                text[1] = UInt8(48 + (index / 100) % 10)
                text[2] = UInt8(48 + (index / 10) % 10)
                text[3] = UInt8(48 + index % 10)

                let ok = withUnsafePointer(to: &text) { pointer -> Bool in
                    fs.create(
                        UnsafeRawPointer(pointer),
                        length: 4,
                        kind  : .file,
                        in    : FSLayout.rootObject
                    ).status == .ok
                }
                if ok { made += 1 }
            }

            #expect(made == 200)

            var seen = 0
            fs.forEachEntry(in: FSLayout.rootObject) { _, _, _ in seen += 1 }
            #expect(seen == 200)
        }
    }


    @Test("a folder walked with a cursor gives every name once, and stops")
    func cursorWalksOnce() {
        withFileSystem { fs, disk in
            for index in 0..<200 {
                var text = InlineArray<8, UInt8>(repeating: 0)
                text[0] = UInt8(ascii: "f")
                text[1] = UInt8(48 + (index / 100) % 10)
                text[2] = UInt8(48 + (index / 10) % 10)
                text[3] = UInt8(48 + index % 10)

                _ = withUnsafePointer(to: &text) { pointer in
                    fs.create(
                        UnsafeRawPointer(pointer), length: 4,
                        kind: .file, in: FSLayout.rootObject
                    )
                }
            }

            var cursor = UInt32(0)
            var seen   = 0
            var last   = UInt32.max

            let before = disk.reads

            while let found = fs.entry(from: cursor, in: FSLayout.rootObject) {
                // Never the same one twice: a cursor that did not advance would
                // hand back the first name for ever, and a bounded caller would
                // never notice.
                #expect(found.entry.object != last)
                last   = found.entry.object
                cursor = found.next
                seen  += 1

                if seen > 400 { break }
            }

            #expect(seen == 200)

            // Two hundred names in four blocks. Each step reads the folder's
            // record and the one block the cursor is in, so the whole walk is
            // about two reads a name. Scanning the folder from the front for
            // every name - which is what asking by position did - is three or
            // four times that, and the gap grows with the folder.
            #expect(disk.reads - before < 600)
        }
    }


    // MARK: - Bytes

    @Test("what was written comes back, across a block boundary")
    func writeThenRead() {
        withFileSystem { fs, _ in
            guard let file = create(&fs, "data.bin") else {
                Issue.record("the file was not created")
                return
            }

            let size = 9000   // more than two blocks
            let out = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
            let back = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
            defer { out.deallocate(); back.deallocate() }

            // The high byte of the index is mixed in on purpose. A pattern
            // that only depends on `index * k` repeats every 256 bytes, so a
            // file system that put every block at the same place would still
            // compare equal at every offset this test looks at.
            let bytes = out.assumingMemoryBound(to: UInt8.self)
            for index in 0..<size {
                bytes[index] = UInt8((index * 7 + 13 + (index >> 8) * 31) & 0xFF)
            }

            let written = fs.write(file, at: 0, from: UnsafeRawPointer(out), count: UInt64(size))
            #expect(written.status == .ok)
            #expect(written.bytes == UInt64(size))

            let read = fs.read(file, at: 0, into: back, count: UInt64(size))
            #expect(read.status == .ok)
            #expect(read.bytes == UInt64(size))

            let got = back.assumingMemoryBound(to: UInt8.self)
            var same = true
            for index in 0..<size where got[index] != bytes[index] { same = false; break }
            #expect(same)

            #expect(fs.object(file)?.size == UInt64(size))
        }
    }


    @Test("a read past the end is short, not wrong")
    func shortReadAtTheEnd() {
        withFileSystem { fs, _ in
            guard let file = create(&fs, "small.bin") else { return }

            var payload = InlineArray<16, UInt8>(repeating: 0xAB)
            _ = withUnsafePointer(to: &payload) { pointer in
                fs.write(file, at: 0, from: UnsafeRawPointer(pointer), count: 16)
            }

            let back = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
            defer { back.deallocate() }

            let read = fs.read(file, at: 8, into: back, count: 64)
            #expect(read.status == .ok)
            #expect(read.bytes == 8)

            let past = fs.read(file, at: 16, into: back, count: 64)
            #expect(past.status == .ok)
            #expect(past.bytes == 0)
        }
    }


    @Test("writing into the middle of a file leaves the rest alone")
    func partialWriteKeepsNeighbours() {
        withFileSystem { fs, _ in
            guard let file = create(&fs, "patch.bin") else { return }

            let size = 4096
            let out = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
            let back = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
            defer { out.deallocate(); back.deallocate() }

            out.initializeMemory(as: UInt8.self, repeating: 0x11, count: size)
            _ = fs.write(file, at: 0, from: UnsafeRawPointer(out), count: UInt64(size))

            // Something else read in between, so the scratch buffer no longer
            // happens to hold this file's block. Without this the test passes
            // even when the partial write never reads the block it is patching.
            guard let other = create(&fs, "other.bin") else { return }
            out.initializeMemory(as: UInt8.self, repeating: 0x22, count: size)
            _ = fs.write(other, at: 0, from: UnsafeRawPointer(out), count: UInt64(size))
            _ = fs.read(other, at: 0, into: back, count: UInt64(size))

            var patch = InlineArray<4, UInt8>(repeating: 0x99)
            _ = withUnsafePointer(to: &patch) { pointer in
                fs.write(file, at: 100, from: UnsafeRawPointer(pointer), count: 4)
            }

            _ = fs.read(file, at: 0, into: back, count: UInt64(size))
            let got = back.assumingMemoryBound(to: UInt8.self)

            #expect(got[99]  == 0x11)
            #expect(got[100] == 0x99)
            #expect(got[103] == 0x99)
            #expect(got[104] == 0x11)
        }
    }


    @Test("a file grown a little at a time stays in one run")
    func growthStaysContiguous() {
        withFileSystem { fs, _ in
            guard let file = create(&fs, "grow.bin") else { return }

            var chunk = InlineArray<512, UInt8>(repeating: 0x5A)

            for step in 0..<10 {
                _ = withUnsafePointer(to: &chunk) { pointer in
                    fs.write(
                        file,
                        at  : UInt64(step) * 512,
                        from: UnsafeRawPointer(pointer),
                        count: 512
                    )
                }
            }

            // Ten writes of half a block: two blocks, and joined onto each other
            // rather than scattered, so one extent holds them.
            #expect(fs.object(file)?.extents == 1)
            #expect(fs.object(file)?.size == 5120)
        }
    }


    // MARK: - Taking things back

    @Test("removing a file gives its blocks back")
    func removalFreesSpace() {
        withFileSystem { fs, _ in
            let before = fs.freeBlocks()

            guard let file = create(&fs, "big.bin") else { return }

            let size = 40960
            let out = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
            defer { out.deallocate() }
            out.initializeMemory(as: UInt8.self, repeating: 0x7E, count: size)

            _ = fs.write(file, at: 0, from: UnsafeRawPointer(out), count: UInt64(size))
            #expect(fs.freeBlocks() < before)

            #expect(remove(&fs, "big.bin") == .ok)
            #expect(find(&fs, "big.bin") == nil)

            // Everything back except the block the root folder grew by.
            #expect(fs.freeBlocks() == before - 1)
        }
    }


    @Test("a folder with something in it is not removed")
    func fullFoldersAreKept() {
        withFileSystem { fs, _ in
            guard let folder = create(&fs, "keep", kind: .folder) else { return }
            #expect(create(&fs, "inside.txt", in: folder) != nil)

            #expect(remove(&fs, "keep") == .notEmpty)
            #expect(find(&fs, "keep") != nil)

            #expect(remove(&fs, "inside.txt", from: folder) == .ok)
            #expect(remove(&fs, "keep") == .ok)
        }
    }


    @Test("the root is the machine's own container, and is not a file")
    func theRootIsSafe() {
        withFileSystem { fs, _ in
            #expect(fs.object(FSLayout.rootObject)?.kind == .container)

            let bytes = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)
            defer { bytes.deallocate() }

            #expect(fs.read(FSLayout.rootObject, at: 0, into: bytes, count: 16).status == .wrongKind)
        }
    }


    @Test("a name freed by a removal is usable again")
    func namesComeBack() {
        withFileSystem { fs, _ in
            #expect(create(&fs, "once.txt") != nil)
            #expect(remove(&fs, "once.txt") == .ok)
            #expect(create(&fs, "once.txt") != nil)
        }
    }


    // MARK: - When the disk stops answering

    @Test("a disk that goes away mid-write does not leave a file claiming bytes it has not got")
    func deviceFailureIsReported() {
        withFileSystem { fs, disk in
            guard let file = create(&fs, "unlucky.bin") else { return }

            let out = UnsafeMutableRawPointer.allocate(byteCount: 8192, alignment: 8)
            defer { out.deallocate() }
            out.initializeMemory(as: UInt8.self, repeating: 0x33, count: 8192)

            disk.failFrom = disk.reads + disk.writes + 3

            let written = fs.write(file, at: 0, from: UnsafeRawPointer(out), count: 8192)
            #expect(written.status == .deviceFailed)

            // The size is only written after the bytes are, so the record never
            // claims more than reached the disk.
            #expect(written.bytes < 8192)
        }
    }
}
