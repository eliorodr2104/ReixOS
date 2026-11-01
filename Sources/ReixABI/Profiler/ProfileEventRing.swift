//
//  ProfileEventRing.swift
//  ReixOS
//

/// One consumer of one attachment. A replacement invalidates the reader;
/// its late cursor stores retain the old tag and cannot acknowledge new data.
/// The caller supplies the platform's full data-memory barrier at each read.
public struct ProfileEventRing {
    public static let dataOffset  = TraceExportRing.recordsOffset
    public static let recordBytes = TraceExportRing.recordBytes

    private let base      : UnsafeMutableRawPointer
    private let consumer  : UnsafeMutableRawPointer
    private let mask      : UInt32
    private let generation: UInt32
    private var head      : UInt32

    public init(base: UnsafeMutableRawPointer, stats: UnsafeMutableRawPointer, mask: UInt32, barrier: () -> Void) {
        self.base = base
        self.consumer = stats + TraceExportRing.consumerOffset
        self.mask = mask
        self.generation = base.load(fromByteOffset: TraceExportRing.generationOffset, as: UInt32.self)
        barrier()
        self.head = TraceExportRing.head(of: consumer.load(as: UInt64.self), generation: generation) ?? 0
    }

    /// Only a validated batch is surfaced. A stale publication can race the
    /// final generation check, so its tag is part of the same aligned store.
    public mutating func drain(barrier: () -> Void) -> (count: Int, dropped: UInt64, generation: UInt32)? {
        guard currentGeneration == generation else { return nil }
        let tail = base.load(fromByteOffset: TraceExportRing.producerOffset, as: UInt32.self)
        barrier()
        let available = tail &- head
        guard available <= mask &+ 1 else { return nil }
        var cursor = head
        while cursor != tail {
            let offset = Self.dataOffset + Int(cursor & mask) * Self.recordBytes
            _ = base.load(fromByteOffset: offset, as: UInt64.self)
            _ = base.load(fromByteOffset: offset + 8, as: UInt16.self)
            _ = base.load(fromByteOffset: offset + 10, as: UInt16.self)
            _ = base.load(fromByteOffset: offset + 12, as: UInt32.self)
            _ = base.load(fromByteOffset: offset + 16, as: UInt64.self)
            _ = base.load(fromByteOffset: offset + 24, as: UInt64.self)
            cursor &+= 1
        }
        let dropped = base.load(fromByteOffset: TraceExportRing.droppedOffset, as: UInt64.self)
        barrier()
        guard currentGeneration == generation else { return nil }
        barrier()
        consumer.storeBytes(of: TraceExportRing.consumer(head: cursor, generation: generation), as: UInt64.self)
        barrier()
        guard currentGeneration == generation else { return nil }
        let count = Int(available)
        head = cursor
        return (count, dropped, generation)
    }

    private var currentGeneration: UInt32 {
        base.load(fromByteOffset: TraceExportRing.generationOffset, as: UInt32.self)
    }
}
