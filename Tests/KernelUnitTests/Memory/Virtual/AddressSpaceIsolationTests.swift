import Testing
@testable import Kernel

@Suite("Address space isolation")
struct AddressSpaceIsolationTests {
    @Test("user descriptors preserve the architectural non-global bit")
    func nonGlobalDescriptor() {
        var entry = AArch64PageTableEntry(rawValue: 0)
        entry.physicalAddress = 0x4000_1000
        entry.mairIndex = .normalCacheable
        entry.shareability = .innerShareable
        entry.flags = [.present, .userAccess, .notGlobal, .pxn, .uxn]
        #expect(entry.rawValue & (1 << 11) != 0)
        #expect(entry.flags.contains(.notGlobal))
        #expect(entry.physicalAddress == 0x4000_1000)
        entry.flags.remove(.notGlobal)
        #expect(entry.rawValue & (1 << 11) == 0)
        #expect(entry.shareability == .innerShareable)
    }

    @Test("eight-bit ASIDs exhaust without aliasing a live space")
    func narrowASIDs() {
        var allocator = ASIDAllocator(bits: 8)
        var live = Set<ASID>()
        for _ in 0..<255 {
            let tag = allocator.allocate()
            #expect(tag != nil && tag != 0)
            if let tag { #expect(live.insert(tag).inserted) }
        }
        let exhausted = allocator.allocate()
        #expect(exhausted == nil)
        allocator.release(127)
        let recycled = allocator.allocate()
        #expect(recycled == 127)
        let stillFull = allocator.allocate()
        #expect(stillFull == nil)
    }

    @Test("churn beyond UInt16 wrap never takes a live process tag")
    func churn() {
        var allocator = ASIDAllocator(bits: 16)
        let held = allocator.allocate()
        #expect(held == 1)
        for _ in 0..<70_000 {
            guard let tag = allocator.allocate() else {
                Issue.record("ASID allocation failed with one live tag")
                return
            }
            #expect(tag != held && tag != 0)
            allocator.release(tag)
        }
    }

    @Test("wide ASIDs expand without losing narrow live tags")
    func wideASIDs() {
        let storage = UnsafeMutablePointer<UInt64>.allocate(capacity: 1024)
        defer { storage.deallocate() }
        var allocator = ASIDAllocator(bits: 16)
        var expansions = 0
        var live = Set<ASID>()
        for _ in 0..<65_535 {
            let tag = allocator.allocate {
                expansions += 1
                return storage
            }
            guard let tag else { Issue.record("wide ASIDs exhausted too early"); return }
            #expect(tag != 0 && live.insert(tag).inserted)
        }
        #expect(expansions == 1)
        let exhausted = allocator.allocate()
        #expect(exhausted == nil)
        allocator.release(32_000)
        let recycled = allocator.allocate()
        #expect(recycled == 32_000)
    }
}
