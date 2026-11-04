import Testing
import ReixABI
@testable import ReixFS

/// Believing the medium's sums is a choice the mount cannot make.
@Suite("A consented sum-root repair", .serialized)
struct ReanchorTests {
    private static let block = Int(FSLayout.blockSize)
    private static let sectors: UInt64 = 4096

    private func scratch() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
    }

    private func prepare<D: BlockDevice>(_ device: D, _ space: UnsafeMutableRawPointer)
        -> (fs: FileSystem<D>, file: UInt32)? {
        guard var fs = FileSystem.format(device, scratch: space).disk else {
            Issue.record("format refused")
            return nil
        }
        let name: StaticString = "kept.bin"
        let made = fs.create(UnsafeRawPointer(name.utf8Start), length: 8,
                             kind: .file, in: FSLayout.rootObject)
        guard made.status == .ok else {
            Issue.record("create refused")
            return nil
        }
        let file = made.object
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: Self.block, alignment: 8)
        defer { bytes.deallocate() }
        bytes.initializeMemory(as: UInt8.self, repeating: 0xA7, count: Self.block)
        guard fs.write(file, at: 0, from: bytes, count: UInt64(Self.block)).status == .ok else {
            Issue.record("write refused")
            return nil
        }
        return (fs, file)
    }

    private func newer(_ a: [UInt8], _ b: [UInt8]) -> UInt32 {
        let first = a.withUnsafeBytes { FSSuperblock(reading: $0.baseAddress!).generation }
        let last = b.withUnsafeBytes { FSSuperblock(reading: $0.baseAddress!).generation }
        return first >= last ? FSLayout.superblockA : FSLayout.superblockB
    }

    private func withVolume(
        sectors: UInt64 = Self.sectors,
        lost: Bool = true,
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk, UInt32) -> Void
    ) {
        let device = MemoryDisk(sectors: sectors)
        let space = scratch()
        defer { space.deallocate() }
        guard var prepared = prepare(device, space) else { return }
        if lost {
            let home = newer(device.block(FSLayout.superblockA), device.block(FSLayout.superblockB))
            device.poke(UInt8(0x5A), at: Int(home) * Self.block + FSSuperblockField.commit)
        }
        body(&prepared.fs, device, prepared.file)
    }

    private func regionRoot(_ device: MemoryDisk, _ plan: FSLayout.Plan) -> UInt32 {
        var root = FSChecksum.empty
        for home in plan.sumStart..<plan.dataStart {
            let sum = device.block(home).withUnsafeBytes {
                FSChecksum.over($0.baseAddress!, count: Self.block)
            }
            root = withUnsafeBytes(of: sum) {
                FSChecksum.over($0.baseAddress!, count: 4, continuing: root)
            }
        }
        return root
    }

    private func changeCopies(_ device: MemoryDisk, _ change: (inout FSSuperblock) -> Void) {
        let plan = FSLayout.Plan(sectorCount: device.sectorCount, sectorSize: device.sectorSize)!
        for home in [FSLayout.superblockA, FSLayout.superblockB] {
            var page = device.block(home)
            page.withUnsafeMutableBytes {
                guard FSSuperblock.verdict(of: $0.baseAddress!, against: plan) == .whole else { return }
                var copy = FSSuperblock(reading: $0.baseAddress!)
                change(&copy)
                copy.write(to: $0.baseAddress!)
            }
            device.put(page, block: home)
        }
    }

    private func disagree(_ device: MemoryDisk, _ plan: FSLayout.Plan) {
        let root = regionRoot(device, plan) ^ 1
        changeCopies(device) { $0.sumRoot = root }
    }

    @Test("only an otherwise clean root mismatch is offered, never another mount refusal",
          arguments: ["healthy", "blank", "foreign", "layout", "superblocks", "journal",
                      "future", "intent", "durability", "exhausted", "stepExhausted", "device"])
    func otherRefusals(_ kind: String) {
        withVolume(lost: kind != "healthy") { fs, device, file in
            switch kind {
                case "blank":
                    for home in [FSLayout.superblockA, FSLayout.superblockB] {
                        device.put([UInt8](repeating: 0, count: Self.block), block: home)
                    }
                case "foreign", "layout", "superblocks":
                    for home in [FSLayout.superblockA, FSLayout.superblockB] {
                        let offset = kind == "superblocks" ? FSSuperblockField.commit : FSSuperblockField.magic
                        let at = Int(home) * Self.block + offset + (kind == "layout" ? 6 : 0)
                        device.poke(UInt8(0x5A), at: at)
                    }
                case "journal":
                    device.poke(UInt8(0), at: Int(fs.plan.journalHeader) * Self.block)
                case "future", "intent", "stepExhausted":
                    var header = FSJournal()
                    header.generation = FSJournal.stamp(mount: fs.superblockGeneration + 1, step: 1)!
                    header.state = kind == "future" ? .committed : .prepared
                    if kind == "stepExhausted" {
                        header.state = .empty
                        header.generation = FSJournal.stamp(mount: fs.superblockGeneration, step: .max)!
                    }
                    if kind == "intent" {
                        let added = header.intent.add(fs.object(file)!.runs[0].start)
                        #expect(added)
                    }
                    var page = [UInt8](repeating: 0, count: Self.block)
                    page.withUnsafeMutableBytes { header.write(to: $0.baseAddress!) }
                    device.put(page, block: fs.plan.journalHeader)
                case "durability": device.durability = .unknown
                case "exhausted": changeCopies(device) { $0.generation = .max }
                case "device": device.failAfter(1)
                default: break
            }
            let space = scratch()
            defer { space.deallocate() }
            let writes = device.writes
            let mount = FileSystem.mount(device, scratch: space)
            #expect((mount.disk != nil) == (kind == "healthy"), "\(kind): \(mount.found)")
            let afterMount = device.writes
            if kind != "healthy" { #expect(afterMount == writes) }
            #expect(!FileSystem.reanchorOffered(device, scratch: space), "\(kind)")
            #expect(FileSystem.reanchor(device, scratch: space, consent: true).disk == nil, "\(kind)")
            #expect(device.writes == afterMount, "\(kind)")
        }
        for sectors in [UInt64(1), UInt64(FSLayout.maxSupportedBlocks + 1) * 8] {
            let device = ClaimedDisk(sectorSize: 512, sectorCount: sectors)
            let space = scratch()
            defer { space.deallocate() }
            #expect(!FileSystem.reanchorOffered(device, scratch: space))
            #expect(FileSystem.reanchor(device, scratch: space, consent: true).disk == nil)
        }
    }

    @Test("a mount and an unanswered offer write nothing")
    func consentAbsent() {
        withVolume { _, device, _ in
            let space = scratch()
            defer { space.deallocate() }
            let writes = device.writes
            let before = [device.block(0), device.block(1)]
            let attempt = FileSystem.mount(device, scratch: space)
            #expect(attempt.disk == nil && isCorrupt(attempt.found))
            #expect(FileSystem.reanchorOffered(device, scratch: space))
            let reads = device.reads
            #expect(FileSystem.reanchor(device, scratch: space, consent: false).disk == nil)
            #expect(device.reads == reads)
            #expect(device.writes == writes)
            #expect([device.block(0), device.block(1)] == before)
        }
    }

    @Test("consent anchors both copies and a later dirty mount passes", arguments: [UInt64(4096), 32768])
    func consentGiven(_ sectors: UInt64) {
        withVolume(sectors: sectors) { fs, device, file in
            let space = scratch()
            defer { space.deallocate() }
            let reads = device.reads
            #expect(FileSystem.reanchorOffered(device, scratch: space))
            let offerReads = device.reads - reads
            let checkpoint = device.block(fs.plan.journalHeader).withUnsafeBytes {
                FSJournal(reading: $0.baseAddress!).generation
            }
            let before = (device.reads, device.writes, device.flushes)
            guard var repaired = FileSystem.reanchor(device, scratch: space, consent: true).disk else {
                Issue.record("repair refused")
                return
            }
            print("re-anchor \(sectors / 2048) MiB: offer \(offerReads) reads; repair \(device.reads - before.0) reads, \(device.writes - before.1) writes, \(device.flushes - before.2) barriers")
            #expect(device.writes - before.1 == 7)
            #expect(device.flushes - before.2 == 4)
            let repairedStamp = device.block(fs.plan.journalHeader).withUnsafeBytes {
                FSJournal(reading: $0.baseAddress!).generation
            }
            #expect(FSJournal.step(of: repairedStamp) == FSJournal.step(of: checkpoint) + 1)
            let root = regionRoot(device, fs.plan)
            for home in [FSLayout.superblockA, FSLayout.superblockB] {
                device.block(home).withUnsafeBytes {
                    #expect(FSSuperblock.verdict(of: $0.baseAddress!, against: fs.plan) == .whole)
                    #expect(FSSuperblock(reading: $0.baseAddress!).sumRoot == root)
                }
            }
            #expect(repaired.read(file, at: 0, into: repaired.dataBuffer, count: 1).status == .ok)
            #expect(repaired.dataBuffer.load(as: UInt8.self) == 0xA7)
            guard var later = FileSystem.mount(device, scratch: space).disk else {
                Issue.record("the dirty mount refused the repair")
                return
            }
            #expect(later.wasDirty)
            #expect(later.scan(.data).safeToServe)
            #expect(device.rootAgrees())
        }
    }

    @Test("any other scan finding prevents both an offer and a consented write",
          arguments: ["table", "folder", "map", "room", "record", "name", "data"])
    func additionalDamage(_ kind: String) {
        withVolume { fs, device, file in
            let table = Int(fs.plan.tableStart) * Self.block
            switch kind {
                case "table": device.poke(UInt8(0x5A), at: table + 200)
                case "folder":
                    let home = fs.object(FSLayout.rootObject)!.runs[0].start
                    device.poke(UInt8(0x5A), at: Int(home) * Self.block + 200)
                case "map":
                    let at = Int(fs.plan.bitmapStart) * Self.block
                    device.poke(device.byte(at: at) ^ 1, at: at)
                case "room":
                    device.poke(UInt32(19), at: table + 36)
                    device.stampBlock(at: table)
                case "record":
                    device.poke(UInt8(0xFF), at: table + Int(file) * Int(FSLayout.objectSize))
                    device.stampBlock(at: table)
                case "name":
                    let at = Int(fs.object(FSLayout.rootObject)!.runs[0].start) * Self.block
                    device.poke(UInt8(0xFF), at: at)
                    device.stampEntry(at: at)
                default:
                    device.poke(UInt8(0), at: Int(fs.object(file)!.runs[0].start) * Self.block)
            }
            disagree(device, fs.plan)
            let space = scratch()
            defer { space.deallocate() }
            let writes = device.writes
            #expect(!FileSystem.reanchorOffered(device, scratch: space), "\(kind)")
            #expect(FileSystem.reanchor(device, scratch: space, consent: true).disk == nil, "\(kind)")
            #expect(device.writes == writes, "\(kind)")
        }
    }

    @Test("the consented scan rereads the medium and refuses damage since the offer")
    func rechecksAfterOffer() {
        withVolume { fs, device, file in
            let space = scratch()
            defer { space.deallocate() }
            #expect(FileSystem.reanchorOffered(device, scratch: space))
            let writes = device.writes
            device.poke(UInt8(0), at: Int(fs.object(file)!.runs[0].start) * Self.block)
            #expect(FileSystem.reanchor(device, scratch: space, consent: true).disk == nil)
            #expect(device.writes == writes)
        }
    }

    @Test("the new root comes from a fresh read of every sum page")
    func rereadsSums() {
        withVolume { fs, device, _ in
            let space = scratch()
            defer { space.deallocate() }
            #expect(FileSystem.reanchorOffered(device, scratch: space))
            let before = regionRoot(device, fs.plan)
            device.poke(UInt8(0x5A), at: Int(fs.plan.dataStart - 1) * Self.block + Self.block - 1)
            #expect(regionRoot(device, fs.plan) != before)
            #expect(FileSystem.reanchor(device, scratch: space, consent: true).disk != nil)
            #expect(device.rootAgrees())
        }
    }

    @Test("a stop at every scan read authorizes no write")
    func stoppedScan() {
        var reads = 0
        withVolume { _, device, _ in
            let space = scratch()
            defer { space.deallocate() }
            let before = device.reads
            #expect(FileSystem.reanchorOffered(device, scratch: space))
            reads = device.reads - before
        }
        #expect(reads > 0)
        for stop in 1...max(reads, 1) {
            withVolume { _, device, _ in
                let space = scratch()
                defer { space.deallocate() }
                let writes = device.writes
                device.refuseOnly(stop)
                #expect(!FileSystem.reanchorOffered(device, scratch: space), "stop \(stop)")
                #expect(device.writes == writes)
                device.refuseOnly(stop)
                #expect(FileSystem.reanchor(device, scratch: space, consent: true).disk == nil)
                #expect(device.writes == writes)
            }
        }
    }

    @Test("clean root refusals are offered after a full scan", arguments: [false, true])
    func cleanRootRefusals(_ sealed: Bool) {
        withVolume(lost: false) { fs, device, _ in
            #expect(fs.unmount() == .ok)
            if !sealed { device.unseal(fs.plan) }
            disagree(device, fs.plan)
            let space = scratch()
            defer { space.deallocate() }
            let writes = device.writes
            let mount = FileSystem.mount(device, scratch: space)
            #expect(mount.disk == nil && isCorrupt(mount.found))
            #expect(FileSystem.reanchorOffered(device, scratch: space))
            #expect(device.writes == writes)
            #expect(FileSystem.reanchor(device, scratch: space, consent: true).disk != nil)
            #expect(device.rootAgrees())
        }
    }

    @Test("a seal's bitmap refusal is not turned into a root repair")
    func otherSealRefusal() {
        withVolume(lost: false) { fs, device, _ in
            #expect(fs.unmount() == .ok)
            let copies = [device.block(0), device.block(1)]
            let name: StaticString = "new.bin"
            #expect(fs.create(UnsafeRawPointer(name.utf8Start), length: 7,
                              kind: .file, in: FSLayout.rootObject).status == .ok)
            device.put(copies[0], block: 0)
            device.put(copies[1], block: 1)
            let space = scratch()
            defer { space.deallocate() }
            let writes = device.writes
            let mount = FileSystem.mount(device, scratch: space)
            #expect(mount.disk == nil && isCorrupt(mount.found))
            #expect(!FileSystem.reanchorOffered(device, scratch: space))
            #expect(FileSystem.reanchor(device, scratch: space, consent: true).disk == nil)
            #expect(device.writes == writes)
        }
    }

    @Test("consent can accept a stale table and sum pair because the medium is believed")
    func stalePairIsTrusted() {
        withVolume(lost: false) { fs, device, _ in
            let table = device.block(fs.plan.tableStart)
            let sums = (fs.plan.sumStart..<fs.plan.dataStart).map { device.block($0) }
            var root = fs.object(FSLayout.rootObject)!
            let old = root.created
            root.created += 1
            #expect(fs.begin() == .ok)
            #expect(fs.finish(fs.store(root, at: FSLayout.rootObject)) == .ok)
            device.put(table, block: fs.plan.tableStart)
            for (index, page) in sums.enumerated() {
                device.put(page, block: fs.plan.sumStart + UInt32(index))
            }
            let space = scratch()
            defer { space.deallocate() }
            #expect(FileSystem.mount(device, scratch: space).disk == nil)
            #expect(FileSystem.reanchorOffered(device, scratch: space))
            guard var repaired = FileSystem.reanchor(device, scratch: space, consent: true).disk else {
                Issue.record("the consented stale pair was refused")
                return
            }
            #expect(repaired.object(FSLayout.rootObject)?.created == old)
            #expect(device.rootAgrees())
        }
    }

    @Test("a tear at every repair transaction request stays refused or mounts whole")
    func tornAtEveryRequest() {
        var scanReads = 0
        var transactionRequests = 0
        withVolume { _, device, _ in
            let space = scratch()
            defer { space.deallocate() }
            let before = (device.reads, device.writes, device.flushes)
            #expect(FileSystem.reanchor(device, scratch: space, consent: true).disk != nil)
            scanReads = device.reads - before.0
            transactionRequests = device.writes - before.1 + device.flushes - before.2
        }
        #expect(transactionRequests == 11)
        for stop in 1...max(transactionRequests, 1) {
            withVolume { _, device, _ in
                let space = scratch()
                defer { space.deallocate() }
                device.tearOnly(scanReads + stop)
                _ = FileSystem.reanchor(device, scratch: space, consent: true)
                device.recover()
                var attempt = FileSystem.mount(device, scratch: space)
                if attempt.disk == nil {
                    #expect(FileSystem.reanchorOffered(device, scratch: space), "stop \(stop)")
                    attempt = FileSystem.reanchor(device, scratch: space, consent: true)
                }
                #expect(attempt.disk != nil, "stop \(stop): \(attempt.found)")
                #expect(device.rootAgrees())
            }
        }
    }

    @Test("a cut at every repair transaction request leaves refusal or a replayable repair")
    func crashAtEveryRequest() {
        var scanReads = 0
        var transactionRequests = 0
        withVolume { _, device, _ in
            let space = scratch()
            defer { space.deallocate() }
            let before = (device.reads, device.writes, device.flushes)
            #expect(FileSystem.reanchor(device, scratch: space, consent: true).disk != nil)
            scanReads = device.reads - before.0
            transactionRequests = device.writes - before.1 + device.flushes - before.2
        }
        #expect(transactionRequests == 11)
        let policies: [CrashDisk.Survivors] = [.nothing, .everything, .single(0), .single(1), .permuted(7)]
        for stop in 1...max(transactionRequests, 1) {
            for policy in policies {
                let device = CrashDisk(sectors: Self.sectors)
                let space = scratch()
                defer { space.deallocate() }
                guard let prepared = prepare(device, space) else { continue }
                let home = newer(device.block(0), device.block(1))
                device.poke(UInt8(0x5A), at: Int(home) * Self.block + FSSuperblockField.commit)
                device.failAfter(scanReads + stop)
                _ = FileSystem.reanchor(device, scratch: space, consent: true)
                device.powerCut(keeping: policy)
                let restarted = CrashDisk(restarting: device)
                var attempt = FileSystem.mount(restarted, scratch: space)
                if attempt.disk == nil {
                    #expect(isCorrupt(attempt.found), "stop \(stop), \(policy)")
                    let writes = restarted.writes
                    #expect(FileSystem.reanchorOffered(restarted, scratch: space), "stop \(stop), \(policy)")
                    #expect(restarted.writes == writes)
                    attempt = FileSystem.reanchor(restarted, scratch: space, consent: true)
                }
                guard var repaired = attempt.disk else {
                    Issue.record("stop \(stop), \(policy): \(attempt.found)")
                    continue
                }
                #expect(restarted.rootAgrees(), "stop \(stop), \(policy)")
                let findings = repaired.scan(.data)
                #expect(findings.complete && findings.safeToServe && findings.damagedData == 0)
                #expect(repaired.read(prepared.file, at: 0, into: repaired.dataBuffer, count: 1).status == .ok)
                #expect(repaired.dataBuffer.load(as: UInt8.self) == 0xA7)
                let header = restarted.block(FSLayout.journalHeaderBlock).withUnsafeBytes {
                    FSJournal(reading: $0.baseAddress!)
                }
                #expect(header.state == .empty)
            }
        }
    }
}
