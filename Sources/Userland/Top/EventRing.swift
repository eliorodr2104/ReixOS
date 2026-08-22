//
//  EventRing.swift
//  ReixOS
//
//  Created by Eliomar on 04/08/2026.
//

import Reix

/// The event ring spanning pages 1-3: `tail` (producer, monotonic) and
/// `head` (consumer, monotonic, ours to advance) are cursors masked only at
/// the point of indexing, exactly like the kernel's own `TraceRing`.
struct EventRing {
    static let dataOffset  = 16
    static let recordBytes = 32

    let base: UnsafeMutableRawPointer
    let mask: UInt32

    var tail: UInt32 { base.load(fromByteOffset: 0, as: UInt32.self) }

    var head: UInt32 {
        get { base.load(fromByteOffset: 4, as: UInt32.self) }
        nonmutating set {
            base.storeBytes(of: newValue, toByteOffset: 4, as: UInt32.self)
        }
    }

    var dropped: UInt64 { base.load(fromByteOffset: 8, as: UInt64.self) }

    /// Drains every record between our last-seen head and the producer's
    /// tail, then publishes the new head. Returns how many were drained.
    ///
    /// Fields are read but not surfaced: nothing Top prints needs them yet,
    /// this just proves out the wire format record by record.
    func drain() -> Int {
        let currentTail = tail

        // Acquire: orders the record reads after this tail load.
        dmbISH()

        var cursor = head
        var count  = 0

        while cursor != currentTail {
            let offset = Self.dataOffset + Int(cursor & mask) * Self.recordBytes

            _ = base.load(fromByteOffset: offset,      as: UInt64.self) // timestamp
            _ = base.load(fromByteOffset: offset + 8,  as: UInt16.self) // code
            _ = base.load(fromByteOffset: offset + 10, as: UInt16.self) // info
            _ = base.load(fromByteOffset: offset + 12, as: UInt32.self) // pid
            _ = base.load(fromByteOffset: offset + 16, as: UInt64.self) // a
            _ = base.load(fromByteOffset: offset + 24, as: UInt64.self) // b

            cursor &+= 1
            count   += 1
        }

        // Release: publish head only once every record has been read.
        dmbISH()
        head = cursor

        return count
    }
}
