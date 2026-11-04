import Testing
import ReixABI
@testable import ReixFS

@Suite("A stopped recovery is incomplete", .serialized)
struct RepairCompletionTests {

    @Test("a stop on a folder or a table in the name walk cannot authorize repair", arguments: [false, true])
    func stoppedNameWalk(folder: Bool) {
        let disk = StoppingDisk()
        let space = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<StoppingDisk>.scratchBytes, alignment: 8
        )
        defer { space.deallocate() }
        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("format refused")
            return
        }
        let name: StaticString = "a.txt"
        #expect(fs.create(UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount,
                          kind: .file, in: FSLayout.rootObject).status == .ok)

        let target = folder ? fs.object(FSLayout.rootObject)!.runs[0].start : fs.plan.tableStart + 1
        let pass = folder ? 1 : 3
        fs.dropCache()
        disk.arm(block: target, pass: pass)
        let writes = disk.medium.writes
        var findings = fs.putRight()
        #expect(disk.hits == pass)
        #expect(!findings.complete)
        #expect(!findings.safeToServe)
        #expect(!findings.mapMended && findings.roomsMended == 0)
        #expect(disk.medium.writes == writes)

        // Give an incomplete report something to repair, so completeness is
        // the reason this door must refuse it.
        findings.reclaimable = 1
        #expect(!findings.repairable)
        #expect(fs.repair(findings) == .notFound)
        #expect(disk.medium.writes == writes)

        disk.arm(block: target, pass: pass)
        let other = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<StoppingDisk>.scratchBytes, alignment: 8
        )
        defer { other.deallocate() }
        let mounted = FileSystem.mount(disk, scratch: other)
        #expect(disk.hits == pass)
        #expect(mounted.disk == nil)
        guard case .corrupt = mounted.found else {
            Issue.record("stopped mount returned \(mounted.found)")
            return
        }
        #expect(disk.medium.writes == writes)
    }

    private final class StoppingDisk: BlockDevice {
        let medium = MemoryDisk(sectors: 32768)
        var sectorSize: UInt64 { medium.sectorSize }
        var sectorCount: UInt64 { medium.sectorCount }
        var maximumRun: UInt64 { medium.maximumRun }
        var durability: BlockDurability { medium.durability }
        var depth: Int { medium.depth }
        private var target: UInt64 = .max
        private var pass = 0
        private(set) var hits = 0

        func arm(block: UInt32, pass: Int) {
            target = UInt64(block) * (FSLayout.blockSize / sectorSize)
            self.pass = pass
            hits = 0
        }

        func read(_ count: UInt64, from sector: UInt64, into bytes: UnsafeMutableRawPointer) -> BlockStatus {
            if sector == target {
                hits += 1
                if hits == pass { return .deviceRefused }
            }
            return medium.read(count, from: sector, into: bytes)
        }

        func write(_ count: UInt64, to sector: UInt64, from bytes: UnsafeRawPointer) -> BlockStatus {
            medium.write(count, to: sector, from: bytes)
        }
        func flush() -> BlockStatus { medium.flush() }
        func begin(_ count: UInt64, from sector: UInt64, slot: Int) -> BlockStatus {
            medium.begin(count, from: sector, slot: slot)
        }
        func collect() -> (slot: Int, status: BlockStatus)? { medium.collect() }
        func buffer(of slot: Int) -> UnsafeRawPointer { medium.buffer(of: slot) }
    }
}
