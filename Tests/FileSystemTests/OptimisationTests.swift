//
//  OptimisationTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.

import Testing
import ReixABI
@testable import ReixFS

/// The four optimisations the plan allows, each one asked for a number first.
///
/// Two of them turn out to be already in the code and are held to it here; two
/// are conditioned on a measurement, and the measurement is the deliverable
/// whichever way it comes out. An optimisation put in without one is a change
/// nobody can defend afterwards, and this file system has already had a round of
/// looking fast while doing the same work twice.
@Suite("Optimisation decisions", .serialized)
struct OptimisationTests {

    private static let sectors: UInt64 = 32768        // 16 MiB
    private static let bigSectors: UInt64 = 524288    // 256 MiB

    private func scratch() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes,
            alignment: 8
        )
    }

    private func microseconds(_ elapsed: Duration) -> Int {
        let parts = elapsed.components
        return Int(parts.seconds) * 1_000_000 + Int(parts.attoseconds / 1_000_000_000_000)
    }

    /// The middle and the twenty-ninth of thirty runs of `body`.
    private func spread(_ body: () -> Void) -> (p50: Int, p95: Int) {
        var times = [Int]()

        for _ in 0..<BenchTests.samples {
            let opened = ContinuousClock.now
            body()
            times.append(microseconds(opened.duration(to: ContinuousClock.now)))
        }

        times.sort()
        return (times[times.count / 2], times[(times.count * 95) / 100])
    }


    // MARK: - 1. Journal coalescing

    @Test("a transaction that touches one target many times pays for it once")
    func coalescing() {
        let disk = MemoryDisk(sectors: Self.sectors)

        let space = scratch()
        defer { space.deallocate() }

        guard let plan = FSLayout.Plan(sectorCount: Self.sectors, sectorSize: 512) else {
            Issue.record("no plan"); return
        }

        let perBlock = FSLayout.blockSize / 512
        disk.journalSectors = (UInt64(plan.journalHeader) * perBlock)
            ..< (UInt64(plan.journalStart + plan.journalBlocks) * perBlock)
        disk.dataSector = UInt64(plan.dataStart) * perBlock

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("format"); return
        }

        let made = fs.create(
            UnsafeRawPointer(("wide.bin" as StaticString).utf8Start),
            length: 8, kind: .file, in: FSLayout.rootObject
        )
        guard made.status == .ok else { Issue.record("create"); return }

        let bytes = UnsafeMutableRawPointer.allocate(byteCount: 16384, alignment: 8)
        defer { bytes.deallocate() }
        bytes.initializeMemory(as: UInt8.self, repeating: 0xEE, count: 16384)

        let home = disk.homeWrites
        let data = disk.dataWrites

        let done = fs.write(made.object, at: 0, from: bytes, count: 16384)
        #expect(done.status == .ok)

        // Four blocks of file, and the bitmap block that says so was changed
        // four times inside the one transaction. It reaches its own place once,
        // and so does the object table block that the record, the quota charge
        // and the size all live in.
        #expect(disk.dataWrites - data == 4)
        #expect(disk.homeWrites - home == 2, "\(disk.homeWrites - home) home writes")

        // Which is the whole of what the coalescing has to buy: without it the
        // bitmap block would reach its place once per block touched, and the
        // table block once per field changed.
        #expect(fs.transactionOverflows == 0)
    }


    // MARK: - 2. The client's window

    @Test("the window is one transaction, however many blocks it covers")
    func oneWindowOneTransaction() {
        let disk = MemoryDisk(sectors: Self.sectors)

        let space = scratch()
        defer { space.deallocate() }

        guard let plan = FSLayout.Plan(sectorCount: Self.sectors, sectorSize: 512) else {
            Issue.record("no plan"); return
        }
        let perBlock = FSLayout.blockSize / 512
        disk.journalSectors = (UInt64(plan.journalHeader) * perBlock)
            ..< (UInt64(plan.journalStart + plan.journalBlocks) * perBlock)
        disk.dataSector = UInt64(plan.dataStart) * perBlock

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("format"); return
        }

        let bytes = UnsafeMutableRawPointer.allocate(byteCount: 16384, alignment: 8)
        defer { bytes.deallocate() }
        bytes.initializeMemory(as: UInt8.self, repeating: 0x11, count: 16384)

        // The same sixty-four kilobytes twice: once in the four requests a
        // client's window allows, once a block at a time.
        var wide = 0
        var thin = 0

        for (name, chunk, tally) in [
            ("wide.bin" as StaticString, 16384, 0), ("thin.bin" as StaticString, 4096, 1)
        ] {
            let made = fs.create(
                UnsafeRawPointer(name.utf8Start),
                length: 8, kind: .file, in: FSLayout.rootObject
            )
            guard made.status == .ok else { Issue.record("create"); return }

            let before = disk.journalWrites + disk.homeWrites
            var at = UInt64(0)

            while at < 65536 {
                let done = fs.write(made.object, at: at, from: bytes, count: UInt64(chunk))
                #expect(done.status == .ok)
                at += UInt64(chunk)
            }

            let spent = disk.journalWrites + disk.homeWrites - before
            if tally == 0 { wide = spent } else { thin = spent }
        }

        // The plan asks for forty per cent off the metadata of the same
        // workload. The window gives more than that, and it gives it without a
        // word of new mechanism: a request is a transaction, so four requests
        // are four commit protocols instead of sixteen.
        #expect(wide * 100 <= thin * 60, "wide \(wide) against thin \(thin)")

        print("  metadata writes for 64 KiB: \(wide) in 16 KiB requests, \(thin) in 4 KiB")
    }


    // MARK: - 3. A resolve cache for the length of one request

    @Test("what a request would save by keeping the record it resolved")
    func resolveCost() {
        let disk = MemoryDisk(sectors: Self.sectors)

        let space = scratch()
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("format"); return
        }

        // Three deep, which is deeper than anything this machine boots with:
        // the machine's container, an app's, and a child's.
        var here = FSLayout.rootObject

        // Less room each time down: a container cannot give away more than it
        // holds, which is the whole quota model, and giving away all of it would
        // leave the parent nothing for its own names.
        for (name, room) in [("app" as StaticString, UInt32(64)), ("child", UInt32(16))] {
            let made = fs.createContainer(
                UnsafeRawPointer(name.utf8Start),
                length: name.utf8CodeUnitCount,
                quota : room,
                in    : here
            )
            guard made.status == .ok else {
                Issue.record("container \(made.status)")
                return
            }
            here = made.object
        }

        let made = fs.create(
            UnsafeRawPointer(("deep.bin" as StaticString).utf8Start),
            length: 8, kind: .file, in: here
        )
        guard made.status == .ok else { Issue.record("create"); return }

        // What the server does on the way into one request: resolve the handle,
        // prove the object is inside the caller's root, then act.
        func request() -> Int {
            let before = disk.reads

            _ = fs.object(made.object)
            _ = fs.contains(made.object, within: FSLayout.rootObject)
            _ = fs.object(made.object)

            return disk.reads - before
        }

        fs.dropCache()
        let cold = request()
        let warm = request()

        let timing = spread { _ = request() }

        print("  resolve+contain, three deep: \(cold) reads cold, \(warm) warm, "
              + "p50 \(timing.p50)us p95 \(timing.p95)us")

        // The four-slot metadata cache already absorbs it: every record on the
        // way up lives in the object table, and the table blocks stay in hand.
        // A cache of records for the length of a request would save no read at
        // all - which is the measurement this optimisation was conditioned on.
        #expect(warm == 0, "a warm resolve cost \(warm) reads")
        #expect(cold <= 2, "a cold resolve cost \(cold) reads")
    }


    // MARK: - 4. Bitmap word at a time

    /// Writes a pattern of used blocks straight onto the medium.
    ///
    /// Filling a disk with one-block files would take a transaction each and
    /// minutes of them. What is being measured is the reading of the map, so the
    /// pattern it reads is written where it reads it.
    private func fragment(
        _ disk: MemoryDisk,
        _ plan: FSLayout.Plan,
        _ used: (UInt32) -> Bool
    ) {
        let base  = Int(plan.bitmapStart) * Int(FSLayout.blockSize)
        let bytes = (Int(plan.totalBlocks) + 7) / 8

        for byte in 0..<bytes {
            var value = UInt8(0)

            for bit in 0..<8 {
                let block = UInt32(byte * 8 + bit)
                guard block < plan.totalBlocks, used(block) else { continue }

                value |= (1 << UInt8(bit))
            }

            disk.poke(value, at: base + byte)
        }
    }


    @Test("the bitmap scan, on three shapes of fragmentation")
    func bitmapScan() {

        // Each one asks for a run the disk cannot give, so every one is a scan of
        // the whole map and nothing is claimed. The three shapes are not
        // decoration: a word-at-a-time scan can skip a word that is all used or
        // all free and can skip nothing in a map that alternates, so a single
        // pattern would answer the question the way it was chosen.
        let shapes: [(String, (UInt32, UInt32, UInt32) -> Bool, UInt32)] = [
            ("every other block used", { block, data, _ in block >= data && block % 2 == 1 }, 2),
            ("used and free in eights", { block, data, _ in
                block >= data && (block / 8) % 2 == 1
            }, 9),
            ("full but the last hundred", { block, data, last in
                block >= data && block < last - 100
            }, 200),
        ]

        for sectors in [Self.sectors, Self.bigSectors] {
            for (name, used, wanted) in shapes {
                let disk = MemoryDisk(sectors: sectors)

                let space = scratch()
                defer { space.deallocate() }

                guard let plan = FSLayout.Plan(sectorCount: sectors, sectorSize: 512),
                      var fs = FileSystem.format(disk, scratch: space).disk
                else {
                    Issue.record("format \(sectors)"); return
                }

                let last = plan.totalBlocks
                fragment(disk, plan) { used($0, plan.dataStart, last) }
                fs.dropCache()

                var found = FSRun.refused(.noSpace)
                let scan = spread { found = fs.allocateRun(wanted) }

                #expect(found.refusal != .ok, "a full disk answered with a run")

                print("  sweep \(plan.totalBlocks) blocks, \(name), run of \(wanted): "
                      + "p50 \(scan.p50)us p95 \(scan.p95)us")
            }
        }
    }


    /// The two ways of reading the same map, timed against each other in the one
    /// run.
    ///
    /// Cross-run timing on this machine varies by about a factor of two - the
    /// host is doing other things - so a before-and-after taken from two runs can
    /// only carry an effect much larger than that. This takes both loops over the
    /// same bytes at the same moment, which is the comparison the change is
    /// actually claiming.
    ///
    /// It measures the loop and not the file system: the sweep's inner step is a
    /// load, a shift and a test per block, and that is what is written out here.
    @Test("a bit at a time against a word at a time, over the same map")
    func scanStyles() {

        let blocks = 65536
        let bytes  = blocks / 8

        let map = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        defer { map.deallocate() }

        let shapes: [(String, (Int) -> Bool)] = [
            ("every other block used", { $0 % 2 == 1 }),
            ("used and free in eights", { ($0 / 8) % 2 == 1 }),
            ("full but the last hundred", { $0 < blocks - 100 }),
        ]

        for (name, used) in shapes {
            for byte in 0..<bytes {
                var value = UInt8(0)
                for bit in 0..<8 where used(byte * 8 + bit) { value |= (1 << UInt8(bit)) }
                map.storeBytes(of: value, toByteOffset: byte, as: UInt8.self)
            }

            var counted = 0

            let perBit = spread {
                counted = 0
                for block in 0..<blocks {
                    let byte = map.loadUnaligned(fromByteOffset: block / 8, as: UInt8.self)
                    if byte & (1 << UInt8(block % 8)) == 0 { counted += 1 }
                }
            }
            let free = counted

            let perWord = spread {
                counted = 0
                for word in 0..<(blocks / 64) {
                    let value = map.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self)

                    if value == UInt64.max { continue }
                    if value == 0 { counted += 64; continue }

                    counted += 64 - value.nonzeroBitCount
                }
            }

            // The same answer, which is the only thing that makes the times
            // comparable at all.
            #expect(counted == free)

            print("  \(blocks) blocks, \(name): bit at a time p50 \(perBit.p50)us, "
                  + "word at a time p50 \(perWord.p50)us")
        }
    }


    /// The run search, both ways, over the same map.
    ///
    /// The number the whole rewrite is for. A bit at a time tests every block on
    /// the disk with a division and a modulo in each; the fold tests every *word*
    /// with about log(count) ANDs, and a word that cannot hold a run that wide is
    /// rejected by one comparison against zero - which is what a disk with every
    /// other block used costs, and what used to cost sixty-four tests.
    ///
    /// Both answers are compared before either time is believed. A faster
    /// function that answers differently is not a faster function.
    @Test("the run search, a bit at a time against a fold, over the same map")
    func runSearchStyles() {

        let bits  = Int(FSLayout.blockSize) * 8       // one bitmap block: 32768 blocks
        let bytes = Int(FSLayout.blockSize)

        let map = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        defer { map.deallocate() }

        // Each shape with the run length that makes it the hard case: a pattern
        // whose free runs are all shorter than what is asked for is the one
        // nothing can shortcut, and it is what a fragmented disk looks like.
        let shapes: [(String, (Int) -> Bool, Int)] = [
            ("every other block used",   { $0 % 2 == 1 },        2),
            ("used and free in eights",  { ($0 / 8) % 2 == 1 },  9),
            ("full but the last twenty", { $0 < bits - 20 },    64),
            ("empty",                    { _ in false },         2),
        ]

        var worst = 1

        for (name, used, count) in shapes {
            for byte in 0..<bytes {
                var value = UInt8(0)
                for bit in 0..<8 where used(byte * 8 + bit) { value |= (1 << UInt8(bit)) }
                map.storeBytes(of: value, toByteOffset: byte, as: UInt8.self)
            }

            var slow: Int? = 0
            var fold: Int? = 0

            // Both behind an opaque call, so what is compared is the two bodies
            // and not which of them the optimiser happened to inline: one lives
            // in this module and the other does not.
            let askSlow: (Int) -> Int? = {
                SlowBitmap.firstRun(map, ofAtLeast: $0, from: 0, bits: bits)
            }
            let askFold: (Int) -> Int? = {
                FSBitmap.firstRun(map, ofAtLeast: $0, from: 0, bits: bits)
            }

            let perBit  = spread { slow = askSlow(count) }
            let perWord = spread { fold = askFold(count) }

            #expect(slow == fold, "\(name): the two disagree about where the run is")

            // A microsecond is the resolution here, so a fold that lands under it
            // is counted as one rather than as a ratio nobody can defend.
            let ratio = perBit.p50 / max(perWord.p50, 1)
            if ratio > worst { worst = ratio }

            print("  run of \(count) in \(bits) blocks, \(name): "
                  + "bit at a time p50 \(perBit.p50)us, fold p50 \(perWord.p50)us")
        }

        // Ten, side by side in one run against a *clean* bit-at-a-time loop. The
        // improvement over the code this replaced is far larger: the sweep row of
        // this suite went from 53580us to 61us on the worst pattern.
        #expect(worst >= 10, "the best improvement measured was \(worst)x")
    }


    /// And the small case, which a rewrite for the large one can quietly ruin.
    ///
    /// Ten thousand claims of one block each, which is what appending to a file
    /// does over and over. A word at a time reads and writes a whole word where a
    /// bit at a time read and wrote one byte, so this is the measurement that
    /// says whether that costs anything.
    @Test("claiming one block at a time is no slower a word at a time")
    func smallClaimsAreNotSlower() {

        let bytes = Int(FSLayout.blockSize)

        let word = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        let slow = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        defer { word.deallocate(); slow.deallocate() }

        word.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        slow.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)

        // A million, so the answer is hundreds of microseconds and not the
        // resolution of the clock: at ten thousand both sides land near one
        // microsecond in an optimised build and the ratio is the timer.
        let claims = 1_000_000

        // Both behind an opaque call. `SlowBitmap` lives in this module and
        // `FSBitmap` does not, so a direct call measures the module boundary
        // rather than the arithmetic: in an optimised build one loop inlines and
        // the other does not, and the difference is the call.
        let setSlow: (Int) -> Void = { SlowBitmap.set(slow, from: $0, count: 1, used: true) }
        let setWord: (Int) -> Void = { FSBitmap.set(word, from: $0, count: 1, used: true) }

        let perBit  = spread { for block in 0..<claims { setSlow(block % (bytes * 8)) } }
        let perWord = spread { for block in 0..<claims { setWord(block % (bytes * 8)) } }

        // The same map afterwards, which is what makes the times comparable.
        for byte in 0..<bytes {
            #expect(
                word.loadUnaligned(fromByteOffset: byte, as: UInt8.self)
                    == slow.loadUnaligned(fromByteOffset: byte, as: UInt8.self),
                "byte \(byte)"
            )
        }

        print("  \(claims) one-block claims: bit at a time p50 \(perBit.p50)us, "
              + "word at a time p50 \(perWord.p50)us")

        // No regression beyond a twentieth, in the configuration this suite
        // runs in. Stated as a ceiling on the *word* time so a slow machine fails
        // the same way a fast one does.
        #if DEBUG
        #expect(
            perWord.p50 <= perBit.p50 + perBit.p50 / 20 + 1,
            "one-block claims got slower: \(perBit.p50)us to \(perWord.p50)us"
        )
        #else
        // Optimised, the reference inlines and `FSBitmap` does not: another
        // module, and this target is not built whole-module. So what is measured
        // is one call per operation, which the freestanding build does not pay.
        #expect(
            perWord.p50 <= perBit.p50 + perBit.p50 / 20 + claims / 1000 + 1,
            "one-block claims got slower than a call each: \(perBit.p50)us to \(perWord.p50)us"
        )
        #endif
    }


    @Test("counting the free blocks, which walks the whole map every time")
    func freeCount() {
        for sectors in [Self.sectors, Self.bigSectors] {
            let disk = MemoryDisk(sectors: sectors)

            let space = scratch()
            defer { space.deallocate() }

            guard let plan = FSLayout.Plan(sectorCount: sectors, sectorSize: 512),
                  var fs = FileSystem.format(disk, scratch: space).disk
            else {
                Issue.record("format \(sectors)"); return
            }

            // A disk nearly full, which is when somebody asks how much room is
            // left. Every `fs.free`, and every space check a client makes, is
            // this walk.
            let last = plan.totalBlocks
            fragment(disk, plan) { $0 >= plan.dataStart && $0 < last - 100 }
            fs.dropCache()

            var free = UInt32(0)
            let count = spread { free = fs.freeBlocks() }

            #expect(free == 100)

            print("  free count \(plan.totalBlocks) blocks, nearly full: "
                  + "p50 \(count.p50)us p95 \(count.p95)us")
        }
    }
}
