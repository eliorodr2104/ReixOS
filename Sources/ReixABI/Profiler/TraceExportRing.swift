//
//  TraceExportRing.swift
//  ReixOS
//

/// The event ring keeps an attachment tag beside its producer. Its consumer
/// lives after the stats slots in page 0, aligned for one tagged 64-bit store.
public enum TraceExportRing {
    public static let producerOffset   = 0
    public static let generationOffset = 4
    public static let droppedOffset    = 8
    public static let recordsOffset    = 16
    public static let recordBytes      = 32
    public static let consumerOffset   = StatsExportPage.processSlotsOffset
        + StatsExportPage.processSlotLimit * StatsExportPage.processSlotStride

    public static func consumer(head: UInt32, generation: UInt32) -> UInt64 {
        UInt64(generation) << 32 | UInt64(head)
    }

    public static func head(of consumer: UInt64, generation: UInt32) -> UInt32? {
        guard UInt32(truncatingIfNeeded: consumer >> 32) == generation else { return nil }
        return UInt32(truncatingIfNeeded: consumer)
    }
}
