//
//  BlockProtocolTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.


import Testing
import ReixABI

/// The contract between a disk and whoever asks it for sectors.
///
/// Both halves of it are here because both are pure: the arithmetic that says
/// whether a run of sectors exists, and the packing that carries a request
/// across a message. Neither needs a disk, and neither should be discovered to
/// be wrong by a disk.
@Suite("Block request contract")
struct BlockProtocolTests {

    private static let sectors: UInt64 = 32768   // the 16 MiB image
    private static let run    : UInt64 = 8       // one page of sectors


    private func fits(_ count: UInt64, at sector: UInt64) -> Bool {
        BlockRange.fits(count, from: sector, in: Self.sectors, limit: Self.run)
    }


    @Test("a run inside the device is accepted, and the last one is inside")
    func insideIsAccepted() {
        #expect(fits(1, at: 0))
        #expect(fits(1, at: Self.sectors - 1))
        #expect(fits(8, at: Self.sectors - 8))
        #expect(fits(8, at: 0))
    }


    @Test("a run that ends past the device is refused")
    func pastTheEndIsRefused() {
        #expect(!fits(1, at: Self.sectors))
        #expect(!fits(2, at: Self.sectors - 1))
        #expect(!fits(8, at: Self.sectors - 7))
    }


    @Test("a run that would wrap the address space is refused")
    func wrappingIsRefused() {
        // The dangerous request: a start near the top and a count that carries
        // the sum round to something small. `sector + count <= sectorCount`
        // accepts every one of these.
        #expect(!fits(8, at: UInt64.max))
        #expect(!fits(8, at: UInt64.max - 3))
        #expect(!fits(1, at: UInt64.max))
    }


    @Test("an empty run, and one longer than a call may carry, are refused")
    func lengthIsBounded() {
        #expect(!fits(0, at: 0))
        #expect(!fits(Self.run + 1, at: 0))
        #expect(!fits(UInt64.max, at: 0))
    }


    @Test("a device with no sectors accepts nothing")
    func emptyDeviceAcceptsNothing() {
        #expect(!BlockRange.fits(1, from: 0, in: 0, limit: Self.run))
    }


    @Test("a sector number survives the trip through a message")
    func sectorSurvivesPacking() {
        for sector in [UInt64(0), 1, 0xFFFF_FFFF, 0x1_0000_0000, 0xDEAD_BEEF_CAFE] {
            let message = BlockOperation.read.transfer(count: 4, sector: sector)

            #expect(BlockOperation.sector(of: message) == sector)
            #expect(message.words[0] == 4)
        }
    }


    @Test("a status survives the trip back")
    func statusSurvivesPacking() {
        for status in [BlockStatus.ok, .outOfRange, .tooLong, .notAttached,
                       .deviceRefused, .volumeHeld, .notMounted, .readOnly,
                       .notAuthorised] {
            #expect(BlockOperation.status(of: BlockOperation.answer(status)) == status)
        }
    }


    @Test("a reply nobody wrote reads as unreachable rather than as success")
    func emptyReplyIsNotSuccess() {
        // `ok` is zero, and an unanswered call leaves zeroes behind. The status
        // word is therefore read through a case that does not exist as a
        // number, which is the only reason a dropped reply cannot pass for a
        // completed request.
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = 0xFFFF

        let corrupt = Message(tag: MessageTag(BlockOperation.read, length: 1), words: words)
        #expect(BlockOperation.status(of: corrupt) == .unreachable)
    }


    @Test("the geometry answer carries the whole device")
    func geometrySurvivesPacking() {
        let message = BlockOperation.geometry(
            sectorSize : 512,
            sectorCount: Self.sectors,
            durability : .onFlush
        )
        let device  = BlockOperation.device(of: message)

        #expect(BlockOperation.status(of: message) == .ok)
        #expect(device.sectorSize == 512)
        #expect(device.sectorCount == Self.sectors)

        let huge = BlockOperation.device(of: BlockOperation.geometry(
            sectorSize : 512,
            sectorCount: 0x3_0000_0000,
            durability : .onFlush
        ))
        #expect(huge.sectorCount == 0x3_0000_0000)
    }
}
