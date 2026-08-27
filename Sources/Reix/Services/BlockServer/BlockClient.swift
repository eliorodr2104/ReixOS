//
//  BlockClient.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// A disk somebody else owns, used as if it were this process's own.
///
/// It conforms to `BlockDevice` and so does the driver, which is the point:
/// code that reads sectors is written once and does not know, or care, which
/// side of an IPC the disk is on.
///
/// The bytes never travel in a message. One page is shared with the server at
/// attach time and every transfer moves through it, so a request costs one
/// round trip and no copying beyond the one into the caller's own memory.
public struct BlockClient: BlockDevice {

    /// One page, which is eight sectors. Bigger windows are a change here and
    /// nowhere else: the server reads the size off the grant.
    /// One page per request in flight.
    ///
    /// It was one page full stop, which was enough for a client that could only
    /// have one request out at a time - and that is what it *could* have, because
    /// a read is a call and a call parks its caller. Now the slot names the page,
    /// so four requests are four pages that do not tread on each other.
    public static let windowPages: UInt64 = UInt64(BlockQueue.depth)

    private static let pageSize: UInt64 = 4096

    /// The server this client talks to. Public because it is not a secret and
    /// because refusing a request the client-side bounds would have caught is
    /// something only a caller holding this can ask for.
    public let endpoint: UInt32

    private let window: UnsafeMutableRawPointer

    public let sectorSize : UInt64
    public let sectorCount: UInt64

    /// What a completed write means on the disk behind this client.
    ///
    /// The server's answer, not this client's guess. A client that assumed a
    /// flush was always needed would pay a round trip per barrier on a disk with
    /// nothing to flush; one that assumed it never was would hand the file
    /// system an order it does not have.
    public let durability: BlockDurability

    /// As many sectors as the shared page holds. A fact about this client's own
    /// window, so it is worked out here rather than asked for.
    /// One page of sectors, and not the whole window.
    ///
    /// The window is four pages so that four transfers can be in flight; each of
    /// them still moves at most a page, because that is the driver's own data
    /// area per slot.
    public var maximumRun: UInt64 { Self.pageSize / sectorSize }

    public var depth: Int { BlockQueue.depth }


    /// Attaches to the server behind `endpoint` and learns what it is serving.
    ///
    /// `nil` when the page cannot be made or the server will not answer for it.
    /// There is no half-attached state to clean up afterwards: the geometry
    /// answer is what makes the attachment real, and it either came or it did
    /// not.
    public init?(block endpoint: UInt32) {

        let shared = shmCreate(pageCount: Self.windowPages)

        guard shared.isValid,
              let window = UnsafeMutableRawPointer(bitPattern: UInt(shared.address))
        else { return nil }

        // Every way out from here gives the page back. An attach that failed
        // used to leave one capability and one physical page behind per attempt,
        // on the path taken precisely when something is already going wrong.
        func giveUp() {
            _ = munmap(addr: shared.address, size: Self.windowPages * Self.pageSize)
            _ = capDrop(shared.handle)
        }

        self.endpoint = endpoint
        self.window   = window

        _ = send(
            handle     : endpoint,
            message    : BlockOperation.attaching(pages: UInt32(Self.windowPages)),
            grant      : shared.handle,
            grantRights: [.read, .write]
        )

        // `ask` is not available yet - `self` is half built - so this one is
        // spelled out. The geometry answer is what makes the attachment real.
        guard case .success(let answer) = call(
            handle : endpoint,
            message: BlockOperation.geometry.transfer(count: 0, sector: 0)
        ),
        answer.message.tag.label == BlockOperation.geometry.rawValue,
        answer.message.tag.length >= 4,
        BlockOperation.status(of: answer.message) == .ok
        else { giveUp(); return nil }

        let device = BlockOperation.device(of: answer.message)

        // The geometry arrived in a message, so it is another process's numbers
        // and not this one's. The four ways it can be unusable are checked in one
        // place, on the host, and refused here before a single byte moves: a
        // sector size of zero divides, a count of zero makes every range check
        // read as past-the-end, a sector wider than a page of the window makes
        // `maximumRun` nothing so every transfer is refused after this attach was
        // accepted, and a size past sixty-four bits of bytes traps the caller
        // that asks how big the disk is.
        guard BlockGeometry.usable(
            sectorSize : device.sectorSize,
            sectorCount: device.sectorCount,
            window     : Self.pageSize
        ) else { giveUp(); return nil }

        self.sectorSize  = device.sectorSize
        self.sectorCount = device.sectorCount
        self.durability  = device.durability
    }


    /// One request, and the reply if there really was one that answers it.
    ///
    /// `nil` when the exchange did not happen, or when what came back is not
    /// shaped like an answer. The caller turns that into `unreachable`, which is
    /// this protocol's own word for it - said explicitly, not decoded out of a
    /// word the transport never wrote.
    private func ask(_ message: Message, expecting label: BlockOperation, words: UInt8 = 1)
    -> ReceivedMessage? {

        guard case .success(let answer) = call(handle: endpoint, message: message) else {
            return nil
        }

        guard answer.message.tag.label == label.rawValue,
              answer.message.tag.length >= words
        else { return nil }

        return answer
    }


    /// Claims the volume, making this process the only one whose writes the
    /// server will carry out.
    ///
    /// Every write answers `notMounted` until this has come back `.ok`, which
    /// is deliberate: a disk with no holder is a disk nobody may change, so a
    /// process that forgets to claim it cannot corrupt anything by accident.
    public func mount() -> BlockStatus {
        guard let answer = ask(BlockOperation.mount.request, expecting: .read) else {
            return .unreachable
        }

        return BlockOperation.status(of: answer.message)
    }


    /// Gives the volume back, which is what makes the disk quiet enough for
    /// somebody holding a read-only view to look at it.
    public func unmount() -> BlockStatus {
        guard let answer = ask(BlockOperation.unmount.request, expecting: .read) else {
            return .unreachable
        }

        return BlockOperation.status(of: answer.message)
    }


    /// Asks the disk to put everything it has taken on the medium.
    ///
    /// One round trip and no bytes: the whole request is the barrier.
    public func flush() -> BlockStatus {
        guard let answer = ask(BlockOperation.flush.request, expecting: .read) else {
            return .unreachable
        }

        return BlockOperation.status(of: answer.message)
    }


    public func read(
        _ count: UInt64,
        from sector: UInt64,
        into destination: UnsafeMutableRawPointer
    ) -> BlockStatus {

        let status = transfer(.read, count: count, sector: sector)
        guard status == .ok else { return status }

        destination.copyMemory(from: window, byteCount: Int(count * sectorSize))
        return .ok
    }


    // MARK: - Several at once

    /// Starts a read without waiting for its admission.
    ///
    /// `begin` is one-way: waiting for a reply after every admission gives a
    /// fast device enough time to complete each request before the next starts,
    /// defeating the queue.  A server-side refusal is filed under `slot` and
    /// comes back from `collect` with the ordinary completion status.  The
    /// result here therefore means only that the begin message was delivered.
    public func begin(
        _ count: UInt64,
        from sector: UInt64,
        slot: Int
    ) -> BlockStatus {

        guard BlockQueue.valid(UInt32(slot)) else { return .tooLong }

        guard holds(count, from: sector) else {
            return count > maximumRun ? .tooLong : .outOfRange
        }

        let delivered = send(
            handle : endpoint,
            message: BlockOperation.beginning(
                count : UInt32(count),
                sector: sector,
                slot  : UInt32(slot),
                write : false
            )
        )

        return delivered.isDelivered ? .ok : .unreachable
    }


    /// Waits for one read to come back and says which it was.
    ///
    /// The server holds this call until something is finished, so it is a wait
    /// and not a poll. A client with nothing outstanding is told so at once
    /// rather than left waiting for an answer nobody is going to produce.
    public func collect() -> (slot: Int, status: BlockStatus)? {

        guard let answer = ask(BlockOperation.collect.request, expecting: .read) else {
            return nil
        }

        let slot = BlockOperation.slot(of: answer.message)
        guard BlockQueue.valid(slot) else { return nil }

        return (Int(slot), BlockOperation.status(of: answer.message))
    }


    /// Where a slot's bytes are: its own page of the window.
    public func buffer(of slot: Int) -> UnsafeRawPointer {
        UnsafeRawPointer(
            window.advanced(
                by: Int(BlockQueue.offset(of: UInt32(slot), pageSize: Self.pageSize))
            )
        )
    }


    public func write(
        _ count: UInt64,
        to sector: UInt64,
        from source: UnsafeRawPointer
    ) -> BlockStatus {

        guard holds(count, from: sector) else {
            return count > maximumRun ? .tooLong : .outOfRange
        }

        window.copyMemory(from: source, byteCount: Int(count * sectorSize))

        return transfer(.write, count: count, sector: sector)
    }


    /// One round trip. The bounds are checked here as well as at the server,
    /// and not out of distrust: a refusal that never leaves the process is the
    /// difference between a mistake costing a comparison and costing a context
    /// switch.
    private func transfer(
        _ operation: BlockOperation,
        count      : UInt64,
        sector     : UInt64
    ) -> BlockStatus {

        guard holds(count, from: sector) else {
            return count > maximumRun ? .tooLong : .outOfRange
        }

        // `queueFull` means later, not no: every slot the server has is out with
        // the device, and the request was not started. Asking again is the whole
        // of the backpressure, and it is bounded because a server that answers
        // this for ever is a server that has stopped completing anything, which
        // is a failure and not a queue.
        for _ in 0..<Self.attempts {

            guard let answer = ask(
                operation.transfer(count: UInt32(count), sector: sector),
                expecting: .read
            ) else { return .unreachable }

            let status = BlockOperation.status(of: answer.message)
            guard status == .queueFull else { return status }
        }

        return .queueFull
    }

    /// How many times a full queue is worth asking again.
    ///
    /// One more than the server has slots, so a client that arrives while every
    /// slot is out gets a turn once each of them has come back.
    private static let attempts = 8
}
