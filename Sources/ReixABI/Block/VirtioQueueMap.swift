//
//  VirtioQueueMap.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

/// Which descriptor chain belongs to which outstanding request.
///
/// Three descriptors are one request - a header the device reads, the data, and
/// a status byte it writes - so chains start every third descriptor and the
/// used ring's id divided by three is the slot it came back for.
///
/// This is the bookkeeping a queue costs. With one request in flight there was
/// none: the head was a constant and the used index had to have moved by exactly
/// one, two checks that were obviously right by inspection. Neither is true of a
/// queue, so what has to be checked instead is that a completion names a chain
/// this driver could have built - and that check is arithmetic, which is why it
/// lives here, where it can be tested without a device.
public enum VirtioQueueMap {

    /// Descriptors per request: header, data, status.
    public static let perRequest: UInt32 = 3

    /// The first descriptor of `slot`'s chain.
    public static func head(of slot: Int) -> UInt32 {
        UInt32(slot) * perRequest
    }

    /// The slot a used-ring id belongs to, or nil when no chain of `depth` slots
    /// could have that id.
    ///
    /// A device is not trusted to answer with an id anybody sent it. The two
    /// ways it can be wrong are an id that is not the head of a chain and one
    /// past the end of the table, and both are refused rather than divided into
    /// a slot number that indexes something else.
    public static func slot(of id: UInt32, depth: Int) -> Int? {
        guard depth > 0, id % perRequest == 0 else { return nil }

        let slot = id / perRequest
        guard slot < UInt32(depth) else { return nil }

        return Int(slot)
    }

    /// How many descriptors a queue of `depth` requests needs, rounded up to the
    /// power of two the ring index arithmetic wants.
    public static func queueLength(for depth: Int) -> UInt64 {
        var length = UInt64(1)
        let wanted = UInt64(depth) * UInt64(perRequest)

        while length < wanted { length <<= 1 }

        return length
    }
}
