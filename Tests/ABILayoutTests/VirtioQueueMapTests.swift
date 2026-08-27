//
//  VirtioQueueMapTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Testing
import ReixABI

/// Matching a completion to the request it came back for.
///
/// With one request in flight this was two checks that were right by inspection:
/// the chain head was a constant, and the used index had to have moved by exactly
/// one. A queue takes both away, and what replaces them is arithmetic against an
/// id the *device* chose - which is the one number in the whole exchange that
/// comes from outside this machine's control.
///
/// So the rule lives where a device is not needed to try it, and these are the
/// answers a driver would otherwise only find out about on a disk.
@Suite("Virtio completion mapping")
struct VirtioQueueMapTests {

    private static let depth = 4

    @Test("every slot's chain maps back to that slot")
    func headsRoundTrip() {
        for slot in 0..<Self.depth {
            let head = VirtioQueueMap.head(of: slot)

            #expect(VirtioQueueMap.slot(of: head, depth: Self.depth) == slot)
        }

        // Chains do not overlap: three descriptors each, in order.
        for slot in 1..<Self.depth {
            #expect(
                VirtioQueueMap.head(of: slot)
                    == VirtioQueueMap.head(of: slot - 1) + VirtioQueueMap.perRequest
            )
        }
    }


    /// The direction that matters. An id the driver never submitted must be
    /// refused, not divided into a slot number that indexes a request somebody
    /// else is waiting on.
    @Test("an id no chain of this driver's starts at is refused")
    func strayIdsAreRefused() {

        // The middle and the end of a chain are not heads.
        for slot in 0..<Self.depth {
            let head = VirtioQueueMap.head(of: slot)

            #expect(VirtioQueueMap.slot(of: head + 1, depth: Self.depth) == nil)
            #expect(VirtioQueueMap.slot(of: head + 2, depth: Self.depth) == nil)
        }

        // Past the table, at the boundary and far beyond it.
        #expect(VirtioQueueMap.slot(of: VirtioQueueMap.head(of: Self.depth), depth: Self.depth) == nil)
        #expect(VirtioQueueMap.slot(of: 0xFFFF_FFFC, depth: Self.depth) == nil)
        #expect(VirtioQueueMap.slot(of: UInt32.max, depth: Self.depth) == nil)

        // And a driver with no slots accepts nothing at all.
        #expect(VirtioQueueMap.slot(of: 0, depth: 0) == nil)
    }


    /// The ring index arithmetic is a mask, so the table has to be a power of two
    /// and big enough for every chain. Too small and two slots share descriptors.
    @Test("the descriptor table is a power of two that holds every chain")
    func queueLengthCovers() {
        for depth in 1...16 {
            let length = VirtioQueueMap.queueLength(for: depth)

            #expect(length >= UInt64(depth) * UInt64(VirtioQueueMap.perRequest))
            #expect(length & (length - 1) == 0)
        }

        // The one this driver uses.
        #expect(VirtioQueueMap.queueLength(for: 4) == 16)

        // Every descriptor a chain names has to be inside the table.
        let length = VirtioQueueMap.queueLength(for: Self.depth)
        let last   = VirtioQueueMap.head(of: Self.depth - 1) + VirtioQueueMap.perRequest - 1

        #expect(UInt64(last) < length)
    }
}
