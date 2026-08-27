//
//  BenchTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.

import Testing
import ReixABI
@testable import ReixFS

/// What the durable file system costs, workload by workload.
///
/// The baseline this had to have before anything is optimised, and it is a
/// baseline of the *journalled* implementation. The numbers from before it -
/// writes that reached a memory-backed disk with nothing ordering them and
/// nothing flushed - measured a different promise, and comparing across that
/// line would credit the journal's cost to whatever came next.
///
/// Two kinds of number, and they are not interchangeable:
///
/// - **Traffic** is exact. `MemoryDisk` counts its own requests, so reads,
///   journal writes, home writes, data writes and flushes are facts, identical
///   on every sample. They are what the ceilings below assert, and a change that
///   moves one of them moves it visibly.
/// - **Time** is a distribution, taken over thirty samples and reported as p50
///   and p95. It is host CPU: the medium is memory, so what it measures is the
///   work this code does per operation and not what a disk would add. Nothing
///   asserts on it, because a timing assertion on a shared machine fails for
///   reasons that are not the code's - it is reported so that a later run has
///   something to be compared against.
///
/// The flushes are counted separately on purpose. A flush is the expensive thing
/// on real hardware and the free thing here, so folding it into a write count
/// would make this disk's totals a poor guide to a real one's.
@Suite("Benchmarks", .serialized)
struct BenchTests {

    /// Thirty samples, which is what the plan asks for and what makes a p95
    /// mean anything at all: the twenty-ninth of thirty.
    static let samples = 30

    private static let sectors: UInt64 = 32768   // 16 MiB, the Makefile's image

    /// The 16 KiB the client's window holds, which is the most one request moves.
    private static let window = 16384


    // MARK: - What a sample counted

    struct Traffic: Equatable {
        var reads   = 0
        var journal = 0
        var home    = 0
        var data    = 0
        var flushes = 0

        /// Every write that was not somebody's file.
        var metadata: Int { journal + home }

        static func - (later: Traffic, earlier: Traffic) -> Traffic {
            Traffic(
                reads  : later.reads   - earlier.reads,
                journal: later.journal - earlier.journal,
                home   : later.home    - earlier.home,
                data   : later.data    - earlier.data,
                flushes: later.flushes - earlier.flushes
            )
        }
    }


    /// One sample's stopwatch, opened and closed around the part being measured.
    ///
    /// Explicit rather than wrapping the whole closure, because every workload
    /// here has a setup - a format, a file, sixty-four kilobytes already
    /// written - and a benchmark that counted its own setup would be measuring
    /// the fixture.
    final class Take {

        private let disk: MemoryDisk
        private var opened: ContinuousClock.Instant? = nil
        private var mark = Traffic()

        private(set) var elapsed: Duration = .zero
        private(set) var traffic = Traffic()

        init(_ disk: MemoryDisk) { self.disk = disk }

        func begin() {
            mark   = now()
            opened = ContinuousClock.now
        }

        func end() {
            let closed = ContinuousClock.now
            guard let opened else { return }

            elapsed = opened.duration(to: closed)
            traffic = now() - mark
        }

        private func now() -> Traffic {
            Traffic(
                reads  : disk.reads,
                journal: disk.journalWrites,
                home   : disk.homeWrites,
                data   : disk.dataWrites,
                flushes: disk.flushes
            )
        }
    }


    /// One workload's answer.
    struct Measured {
        let name   : String
        let traffic: Traffic
        let p50    : Int      // microseconds
        let p95    : Int
        let steady : Bool     // every sample counted the same traffic
    }


    // MARK: - Running one

    /// Runs `sample` thirty times and reports the traffic and the distribution.
    ///
    /// A fresh disk per sample, so nothing a sample did is paid for by the next
    /// one: a bitmap block left dirty in the cache or a folder one block bigger
    /// would make the first sample the only honest one.
    private func bench(
        _ name: String,
        _ sample: (Take, MemoryDisk) -> Void
    ) -> Measured {

        var times   = [Int]()
        var traffic : Traffic? = nil
        var steady  = true

        for _ in 0..<Self.samples {
            let disk = MemoryDisk(sectors: Self.sectors)

            // The two boundaries that split a write three ways. Known before the
            // disk is formatted, because the layout is a calculation over the
            // device's size and not something read off it.
            if let plan = FSLayout.Plan(sectorCount: Self.sectors, sectorSize: 512) {
                let perBlock = FSLayout.blockSize / 512

                disk.journalSectors =
                    (UInt64(plan.journalHeader) * perBlock)
                    ..< (UInt64(plan.journalStart + plan.journalBlocks) * perBlock)

                disk.dataSector = UInt64(plan.dataStart) * perBlock
            }

            let take = Take(disk)
            sample(take, disk)

            let components = take.elapsed.components
            times.append(
                Int(components.seconds) * 1_000_000
                + Int(components.attoseconds / 1_000_000_000_000)
            )

            if let traffic, traffic != take.traffic { steady = false }
            if traffic == nil { traffic = take.traffic }
        }

        times.sort()

        return Measured(
            name   : name,
            traffic: traffic ?? Traffic(),
            p50    : times[times.count / 2],
            p95    : times[(times.count * 95) / 100],
            steady : steady
        )
    }


    // MARK: - Fixtures

    private func scratch() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes,
            alignment: 8
        )
    }

    private func page(_ bytes: Int) -> UnsafeMutableRawPointer {
        let room = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        room.initializeMemory(as: UInt8.self, repeating: 0xCD, count: bytes)
        return room
    }

    @discardableResult
    private func file(
        _ fs: inout FileSystem<MemoryDisk>,
        _ name: StaticString = "bench.bin"
    ) -> UInt32? {
        let made = fs.create(
            UnsafeRawPointer(name.utf8Start),
            length: name.utf8CodeUnitCount,
            kind  : .file,
            in    : FSLayout.rootObject
        )
        return made.status == .ok ? made.object : nil
    }

    /// `n<nnn>`, so a folder can be filled in order.
    private func named(_ index: Int, _ body: (UnsafeRawPointer, Int) -> Void) {
        var name = InlineArray<8, UInt8>(repeating: 0)
        name[0] = UInt8(ascii: "n")
        name[1] = UInt8(0x30 + UInt8(index / 100 % 10))
        name[2] = UInt8(0x30 + UInt8(index / 10 % 10))
        name[3] = UInt8(0x30 + UInt8(index % 10))

        name.span.withUnsafeBufferPointer { buffer in
            body(UnsafeRawPointer(buffer.baseAddress!), 4)
        }
    }


    // MARK: - The table

    private func report(_ rows: [Measured]) {
        print("")
        print("workload                    reads  jrnl  home  data  flush     p50us     p95us")
        print("------------------------------------------------------------------------------")

        for row in rows {
            var line = row.name
            while line.count < 26 { line += " " }

            func column(_ value: Int, _ width: Int) -> String {
                var text = String(value)
                while text.count < width { text = " " + text }
                return text
            }

            line += column(row.traffic.reads, 7)
            line += column(row.traffic.journal, 6)
            line += column(row.traffic.home, 6)
            line += column(row.traffic.data, 6)
            line += column(row.traffic.flushes, 7)
            line += column(row.p50, 10)
            line += column(row.p95, 10)

            if !row.steady { line += "  (traffic varied)" }

            print(line)
        }
        print("")
    }


    // MARK: - The baseline

    @Test("the durable file system's cost, workload by workload")
    func baseline() {

        var rows = [Measured]()

        // format
        rows.append(bench("format") { take, disk in
            let space = scratch()
            defer { space.deallocate() }

            take.begin()
            let made = FileSystem.format(disk, scratch: space)
            take.end()

            #expect(made.disk != nil)
        })

        // create
        rows.append(bench("create") { take, disk in
            let space = scratch()
            defer { space.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk else { return }

            take.begin()
            let made = fs.create(
                UnsafeRawPointer(("bench.bin" as StaticString).utf8Start),
                length: 9, kind: .file, in: FSLayout.rootObject
            )
            take.end()

            #expect(made.status == .ok)
        })

        // 16 x 4 KiB append
        rows.append(bench("append 16x4KiB") { take, disk in
            let space = scratch()
            defer { space.deallocate() }
            let bytes = page(4096)
            defer { bytes.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk,
                  let object = file(&fs)
            else { return }

            take.begin()
            for step in 0..<16 {
                let done = fs.write(object, at: UInt64(step) * 4096, from: bytes, count: 4096)
                #expect(done.status == .ok)
            }
            take.end()
        })

        // 4 x 16 KiB append: the same sixty-four kilobytes, in the window the
        // client actually has.
        rows.append(bench("append 4x16KiB") { take, disk in
            let space = scratch()
            defer { space.deallocate() }
            let bytes = page(Self.window)
            defer { bytes.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk,
                  let object = file(&fs)
            else { return }

            take.begin()
            for step in 0..<4 {
                let done = fs.write(
                    object, at: UInt64(step * Self.window),
                    from: bytes, count: UInt64(Self.window)
                )
                #expect(done.status == .ok)
            }
            take.end()
        })

        // one 16 KiB write
        rows.append(bench("write 16KiB") { take, disk in
            let space = scratch()
            defer { space.deallocate() }
            let bytes = page(Self.window)
            defer { bytes.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk,
                  let object = file(&fs)
            else { return }

            take.begin()
            let done = fs.write(object, at: 0, from: bytes, count: UInt64(Self.window))
            take.end()

            #expect(done.status == .ok)
        })

        // read 64 KiB, in the four requests a client would make
        rows.append(bench("read 64KiB") { take, disk in
            let space = scratch()
            defer { space.deallocate() }
            let bytes = page(Self.window)
            defer { bytes.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk,
                  let object = file(&fs)
            else { return }

            for step in 0..<4 {
                _ = fs.write(
                    object, at: UInt64(step * Self.window),
                    from: bytes, count: UInt64(Self.window)
                )
            }
            fs.dropCache()

            take.begin()
            for step in 0..<4 {
                let got = fs.read(
                    object, at: UInt64(step * Self.window),
                    into: bytes, count: UInt64(Self.window)
                )
                #expect(got.bytes == UInt64(Self.window))
            }
            take.end()
        })

        // list 10 and list 100, in the batches a client asks for
        for count in [10, 100] {
            rows.append(bench("list \(count)") { take, disk in
                let space = scratch()
                defer { space.deallocate() }
                let room = UnsafeMutableRawPointer.allocate(
                    byteCount: 32 * FSListEntry.width, alignment: 8
                )
                defer { room.deallocate() }

                guard var fs = FileSystem.format(disk, scratch: space).disk else { return }

                for index in 0..<count {
                    named(index) { name, length in
                        _ = fs.create(name, length: length, kind: .file, in: FSLayout.rootObject)
                    }
                }
                fs.dropCache()

                var cursor = UInt32(0)
                var seen   = 0
                var calls  = 0

                take.begin()
                while calls < 20 {
                    let batch = fs.entries(
                        from: cursor, in: FSLayout.rootObject, into: room, capacity: 32
                    )
                    calls += 1
                    seen  += batch.count

                    if batch.eof || batch.status != .ok { break }
                    cursor = batch.next
                }
                take.end()

                #expect(seen == count)
                #expect(calls == (count + 31) / 32)
            })
        }

        // scrub, on a volume that was put down tidily and on one that was not
        rows.append(bench("mount clean") { take, disk in
            let space = scratch()
            defer { space.deallocate() }
            let second = scratch()
            defer { second.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk,
                  file(&fs) != nil,
                  fs.unmount() == .ok
            else { return }

            take.begin()
            let opened = FileSystem.mount(disk, scratch: second)
            take.end()

            #expect(opened.disk != nil)
        })

        rows.append(bench("mount dirty") { take, disk in
            let space = scratch()
            defer { space.deallocate() }
            let second = scratch()
            defer { second.deallocate() }

            // No unmount: the superblock still says somebody is using it, which
            // is what every boot in the scenario matrix meets.
            guard var fs = FileSystem.format(disk, scratch: space).disk,
                  file(&fs) != nil
            else { return }

            take.begin()
            let opened = FileSystem.mount(disk, scratch: second)
            take.end()

            #expect(opened.disk != nil)
        })

        rows.append(bench("scrub clean") { take, disk in
            let space = scratch()
            defer { space.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk else { return }

            for index in 0..<10 {
                named(index) { name, length in
                    _ = fs.create(name, length: length, kind: .file, in: FSLayout.rootObject)
                }
            }
            fs.dropCache()

            take.begin()
            let findings = fs.scan(.everything)
            take.end()

            #expect(findings.complete)
            #expect(!findings.damaged)
        })

        rows.append(bench("scrub dirty") { take, disk in
            let space = scratch()
            defer { space.deallocate() }
            let second = scratch()
            defer { second.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk else { return }

            for index in 0..<10 {
                named(index) { name, length in
                    _ = fs.create(name, length: length, kind: .file, in: FSLayout.rootObject)
                }
            }

            // Mounted again without an unmount, then scrubbed: the volume the
            // shell's `fs.scrub` meets after a power cut.
            guard var dirty = FileSystem.mount(disk, scratch: second).disk else { return }
            dirty.dropCache()

            take.begin()
            let findings = dirty.scan(.everything)
            take.end()

            #expect(findings.complete)
        })

        report(rows)

        // MARK: The goals the plan sets

        guard let small = rows.first(where: { $0.name == "append 16x4KiB" }),
              let large = rows.first(where: { $0.name == "append 4x16KiB" }),
              let ten   = rows.first(where: { $0.name == "list 10" })
        else {
            Issue.record("a workload did not run")
            return
        }

        // Ten names: one pass and at most two reads. The wire cost is one
        // request, which `calls` above asserts.
        #expect(ten.traffic.reads <= 2)

        // The same sixty-four kilobytes, written in the window the client has
        // rather than a block at a time, costs at most sixty per cent of the
        // metadata writes: the plan asks for forty per cent off and the journal
        // gives more, because one transaction stages one bitmap block and one
        // record however many blocks it touches.
        #expect(large.traffic.metadata * 100 <= small.traffic.metadata * 60)

        // And the data is the same either way. A saving that moved bytes out of
        // the file would not be a saving.
        #expect(large.traffic.data == small.traffic.data)

        // Every count above is a fact, not an average.
        for row in rows {
            #expect(row.steady, "\(row.name) did not cost the same twice")
        }
    }
}
