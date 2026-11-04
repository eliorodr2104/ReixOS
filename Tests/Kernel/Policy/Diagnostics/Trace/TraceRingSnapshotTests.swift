import Testing
@testable import Kernel

/// The ring is global; run with `swift test --no-parallel`.
extension KernelPolicyTestRoot {
@Suite("Trace ring snapshot", .serialized)
struct TraceRingSnapshotTests {
    @Test("a walk excludes events appended after its starting head")
    func fixedEnd() {
        TraceRing.reset()
        defer { TraceRing.reset() }
        TraceRing.append(TraceEvent(timestamp: 1))
        TraceRing.append(TraceEvent(timestamp: 2))
        var seen: [UInt64] = []
        TraceRing.forEachEvent { event in
            seen.append(event.timestamp)
            if seen.count == 1 { TraceRing.append(TraceEvent(timestamp: 3)) }
        }
        #expect(seen == [1, 2])
    }
    @Test("empty and full snapshots stop at their captured head")
    func boundaries() {
        TraceRing.reset()
        defer { TraceRing.reset() }
        var empty = TraceRing.snapshot()
        TraceRing.append(TraceEvent(timestamp: 999))
        #expect(empty.next() == nil)
        #expect(!empty.invalidated)
        TraceRing.reset()
        for index in 0..<TraceRing.capacity {
            TraceRing.append(TraceEvent(timestamp: UInt64(index)))
        }
        var snapshot = TraceRing.snapshot()
        for index in 0..<TraceRing.capacity {
            #expect(snapshot.next()?.timestamp == UInt64(index))
            TraceRing.append(TraceEvent(timestamp: UInt64(10000 + index)))
        }
        #expect(snapshot.remaining == 0)
        #expect(snapshot.next() == nil)
        #expect(!snapshot.invalidated)
    }

    @Test("an overwritten unread slot is refused instead of read as a newer event")
    func unreadEviction() {
        TraceRing.reset()
        defer { TraceRing.reset() }
        for index in 0..<TraceRing.capacity {
            TraceRing.append(TraceEvent(timestamp: UInt64(index)))
        }
        var snapshot = TraceRing.snapshot()
        TraceRing.append(TraceEvent(timestamp: 9999))
        #expect(snapshot.next() == nil)
        #expect(snapshot.invalidated)
        #expect(snapshot.remaining == Int(TraceRing.capacity))
        #expect(snapshot.lost == 0)
        #expect(TraceRing.lost == 1)
    }

    @Test("a reset between reads invalidates the old generation")
    func resetGeneration() {
        TraceRing.reset()
        defer { TraceRing.reset() }
        TraceRing.append(TraceEvent(timestamp: 1))
        TraceRing.append(TraceEvent(timestamp: 2))
        var snapshot = TraceRing.snapshot()
        #expect(snapshot.next()?.timestamp == 1)
        TraceRing.reset()
        TraceRing.append(TraceEvent(timestamp: 3))
        #expect(snapshot.next() == nil)
        #expect(snapshot.invalidated)
        var current = TraceRing.snapshot()
        #expect(current.next()?.timestamp == 3)
        #expect(current.next() == nil)
    }

    @Test("protection refuses a second owner and stale release leaves the new owner intact")
    func protectionOwnership() throws {
        TraceRing.reset()
        defer { TraceRing.reset() }
        for index in 0..<TraceRing.capacity {
            TraceRing.append(TraceEvent(timestamp: UInt64(index)))
        }
        let first = try #require(TraceRing.protectSnapshot())
        #expect(TraceRing.protectSnapshot() == nil)
        first.release()
        var second = try #require(TraceRing.protectSnapshot())
        defer { second.release() }
        first.release()
        let rejected = TraceRing.rejected
        TraceRing.append(TraceEvent(timestamp: 9999))
        #expect(TraceRing.rejected == rejected + 1)
        #expect(second.next()?.timestamp == 0)
        TraceRing.append(TraceEvent(timestamp: 10000))
        #expect(TraceRing.rejected == rejected + 1)
        #expect(second.next()?.timestamp == 1)
        TraceRing.reset()
        TraceRing.append(TraceEvent(timestamp: 20000))
        let third = try #require(TraceRing.protectSnapshot())
        second.release()
        #expect(TraceRing.protectSnapshot() == nil)
        third.release()
    }

}
}
