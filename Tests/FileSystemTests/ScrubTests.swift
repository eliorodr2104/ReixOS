//
//  ScrubTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// Looking, and only then putting right.
///
/// A scan used to be a repair: it rebuilt the block map as it went, during a
/// mount, and if a read failed part way it returned the numbers it had with
/// nothing to say they were partial. The repair on offer is "give back the
/// blocks no record owns", and *no record owns them* is a claim about every
/// record - so a scan that stopped in the middle of the object table has not
/// reached the owner, and acting on it hands a live file's blocks away.
///
/// So: a scan reads and writes nothing, says whether it finished, and a repair
/// refuses without that. These tests are mostly about the refusing.
@Suite("A scan looks, a repair writes, and not the other way round")
struct ScrubTests {

    private static let sectors: UInt64 = 4096


    private func withDisk(
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void
    ) {
        let disk = MemoryDisk(sectors: Self.sectors)

        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes,
            alignment: 8
        )
        defer { scratch.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: scratch).disk else {
            Issue.record("the fixture disk would not format")
            return
        }

        body(&fs, disk)
    }


    @discardableResult
    private func make(
        _ fs: inout FileSystem<MemoryDisk>,
        _ name: StaticString,
        kind: FSKind = .file,
        in folder: UInt32 = FSLayout.rootObject
    ) -> UInt32? {
        let made = fs.create(
            UnsafeRawPointer(name.utf8Start),
            length: name.utf8CodeUnitCount,
            kind  : kind,
            in    : folder
        )
        guard made.status == .ok else {
            Issue.record("the fixture object would not be made")
            return nil
        }
        return made.object
    }


    // MARK: - A scan does not write

    @Test("a scan changes nothing, whatever it finds")
    func scanIsReadOnly() {
        withDisk { fs, disk in
            // Something to find: blocks taken and never owned, which is exactly
            // what a machine dying between the two writes leaves behind.
            guard fs.allocateRun(6) != nil else {
                Issue.record("the blocks were not allocated")
                return
            }

            let before = disk.writes
            let findings = fs.scan()

            #expect(findings.reclaimable == 6)
            #expect(findings.complete)
            #expect(disk.writes == before, "a scan wrote to the disk")
        }
    }


    @Test("and a repair afterwards does")
    func repairWrites() {
        withDisk { fs, disk in
            guard fs.allocateRun(6) != nil else { return }

            let findings = fs.scan()
            #expect(findings.repairable)

            let before = disk.writes
            #expect(fs.repair(findings) == .ok)
            #expect(disk.writes > before)

            // And a second look finds nothing left to do.
            #expect(!fs.scan().changed)
        }
    }


    // MARK: - The refusing

    @Test("a scan that stopped repairs nothing, even having found something")
    func incompleteScanRepairsNothing() {
        // The one that matters, and it has to be set up carefully to mean
        // anything: the scan must get far enough to *find* the blocks and then
        // stop, or `complete` is not what is doing the refusing and this test
        // would pass with the guard taken out.
        //
        // So the blocks are counted by the shallow pass, which succeeds, and the
        // failure lands in the walk of the names afterwards.
        withDisk { fs, disk in
            guard fs.allocateRun(6) != nil else { return }

            guard let folder = make(&fs, "docs", kind: .folder),
                  make(&fs, "a.txt", in: folder) != nil
            else { return }

            var stopped = false

            // Where the shallow pass has finished counting and the walk of the
            // names has not. It used to be ten times further along: the object
            // table is four blocks on this disk and all four stay in hand, so
            // the whole scan now costs a handful of round trips rather than a
            // hundred and forty.
            for step in [5, 8, 11, 14] {
                withDisk { inner, disk in
                    guard inner.allocateRun(6) != nil,
                          let folder = make(&inner, "docs", kind: .folder),
                          make(&inner, "a.txt", in: folder) != nil
                    else { return }

                    disk.failAfter(step)
                    let findings = inner.scan(.everything)
                    disk.recover()

                    guard findings.changed, !findings.complete else { return }
                    stopped = true

                    // Found something, and refused anyway. This is the whole
                    // point: what was found is a claim about records the scan
                    // never reached.
                    #expect(!findings.repairable)

                    let before = disk.writes
                    #expect(inner.repair(findings) != .ok)
                    #expect(disk.writes == before, "a partial scan led to a write")
                }
            }

            #expect(stopped, "no step stopped the scan after it had found something")
        }
    }


    @Test("a record the scan could not read stops the repair")
    func impossibleRecordStopsTheRepair() {
        // The other half of the same argument: a record that could not be parsed
        // is an owner that was not understood, and rebuilding the map without it
        // frees that record's blocks for having been unreadable.
        withDisk { fs, disk in
            guard let object = make(&fs, "victim.bin") else { return }

            let payload = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 8)
            defer { payload.deallocate() }
            payload.initializeMemory(as: UInt8.self, repeating: 7, count: 4096)

            #expect(fs.write(
                object, at: 0, from: UnsafeRawPointer(payload), count: 4096
            ).status == .ok)

            // A run pointing into the file system's own blocks, which no record
            // written by this format can hold.
            let at = Int(fs.plan.tableStart) * Int(FSLayout.blockSize)
                + Int(object) * Int(FSLayout.objectSize)
            disk.poke(UInt32(1), at: at + 64)

            // A poke is another writer, and a cache cannot see one. Nothing on a
            // mounted volume writes behind the file system's back; this does,
            // which is the whole point of it.
            fs.dropCache()

            let findings = fs.scan()

            #expect(findings.impossible > 0)
            #expect(findings.complete)
            #expect(!findings.repairable, "a record nobody could read led to a repair")

            let before = disk.writes
            #expect(fs.repair(findings) != .ok)
            #expect(disk.writes == before)
        }
    }


    // MARK: - What the deep scan sees

    @Test("a name whose target disagrees is found")
    func strayNameIsFound() {
        withDisk { fs, disk in
            guard let vault = {
                let name = "vault" as StaticString
                let made = fs.createContainer(
                    UnsafeRawPointer(name.utf8Start),
                    length: name.utf8CodeUnitCount,
                    quota : 32,
                    in    : FSLayout.rootObject
                )
                return made.status == .ok ? made.object : nil
            }() else { return }

            guard let hidden = make(&fs, "secret.bin", in: vault),
                  let folder = make(&fs, "outside", kind: .folder),
                  make(&fs, "loot.bin", in: folder) != nil
            else { return }

            // Repoint the entry at something in the other container, which is
            // the shape a forged name takes.
            guard let host = fs.object(folder) else { return }
            let block = Int(host.runs[0].start) * Int(FSLayout.blockSize)

            var slot: Int? = nil
            for index in 0..<Int(FSLayout.blockSize / FSLayout.entrySize) {
                let at = block + index * Int(FSLayout.entrySize)
                if disk.byte(at: at + 4) == 8 { slot = at }     // "loot.bin"
            }
            guard let slot else {
                Issue.record("the planted entry is not on the disk")
                return
            }
            disk.poke(hidden, at: slot)

            // The shallow scan cannot see it: it never looks at a name.
            #expect(fs.scan(.blocks).strayNames == 0)

            let deep = fs.scan(.everything)
            #expect(deep.complete)
            #expect(deep.strayNames > 0)
            #expect(deep.damaged)
        }
    }


    @Test("a second name for the same thing in one folder is found")
    func duplicateNameIsFound() {
        withDisk { fs, disk in
            guard let folder = make(&fs, "docs", kind: .folder),
                  let first = make(&fs, "a.txt", in: folder),
                  make(&fs, "b.txt", in: folder) != nil
            else { return }

            // Make the second entry's name the same as the first's, so the
            // second is shadowed and can never be reached.
            guard let host = fs.object(folder) else { return }
            let block = Int(host.runs[0].start) * Int(FSLayout.blockSize)

            for index in 0..<Int(FSLayout.blockSize / FSLayout.entrySize) {
                let at = block + index * Int(FSLayout.entrySize)
                guard disk.byte(at: at + 4) == 5 else { continue }        // "?.txt"

                if disk.byte(at: at + 8) == UInt8(ascii: "b") {
                    disk.poke(UInt8(ascii: "a"), at: at + 8)
                }
            }

            let deep = fs.scan(.everything)

            #expect(deep.complete)
            #expect(deep.duplicateNames > 0)

            // And the first one is still perfectly reachable.
            let name = "a.txt" as StaticString
            #expect(fs.lookup(
                UnsafeRawPointer(name.utf8Start),
                length: name.utf8CodeUnitCount,
                in    : folder
            ) == first)
        }
    }


    @Test("a container whose room does not add up is found")
    func wrongQuotaIsFound() {
        withDisk { fs, disk in
            let name = "app" as StaticString
            let made = fs.createContainer(
                UnsafeRawPointer(name.utf8Start),
                length: name.utf8CodeUnitCount,
                quota : 32,
                in    : FSLayout.rootObject
            )
            guard made.status == .ok else { return }

            guard let file = make(&fs, "a.bin", in: made.object) else { return }

            let payload = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 8)
            defer { payload.deallocate() }
            payload.initializeMemory(as: UInt8.self, repeating: 3, count: 4096)

            #expect(fs.write(
                file, at: 0, from: UnsafeRawPointer(payload), count: 4096
            ).status == .ok)

            // Nothing to say yet.
            #expect(fs.scan(.everything).wrongQuota == 0)

            // Now say the container has spent a block it has not.
            let at = Int(fs.plan.tableStart) * Int(FSLayout.blockSize)
                + Int(made.object) * Int(FSLayout.objectSize)
            disk.poke(UInt32(29), at: at + 36)      // used
            fs.dropCache()

            let deep = fs.scan(.everything)

            #expect(deep.complete)
            #expect(deep.quotasChecked)
            #expect(deep.wrongQuota == 1)
        }
    }


    @Test("an object that is its own parent is found")
    func selfParentIsFound() {
        withDisk { fs, disk in
            guard let folder = make(&fs, "loop", kind: .folder) else { return }

            let at = Int(fs.plan.tableStart) * Int(FSLayout.blockSize)
                + Int(folder) * Int(FSLayout.objectSize)
            disk.poke(folder, at: at + 44)          // parent
            fs.dropCache()

            let findings = fs.scan()

            #expect(findings.selfParented == 1)
            #expect(findings.damaged)

            // The machine's own root is its own parent and is not a loop.
            #expect(findings.selfParented == 1)
        }
    }


    @Test("a healthy disk comes through both depths with nothing to say")
    func healthyDiskIsQuiet() {
        withDisk { fs, disk in
            guard let folder = make(&fs, "docs", kind: .folder),
                  make(&fs, "a.txt", in: folder) != nil,
                  make(&fs, "b.txt", in: folder) != nil
            else { return }

            let before = disk.writes

            for depth in [FileSystem<MemoryDisk>.Scrub.blocks, .everything] {
                let findings = fs.scan(depth)

                #expect(findings.complete)
                #expect(!findings.damaged)
                #expect(!findings.changed)
            }

            #expect(disk.writes == before)
        }
    }
}
