//
//  VirtioBlock.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import Reix
import ReixABI

/// A virtio block device, brought up and read from.
///
/// Everything it needs arrives in its initialiser: a window on the transport's
/// registers and a capability for the line it raises. It asks for nothing else
/// and looks nothing up, which is what will let it move into a process of its
/// own later without a line of it changing.
///
/// Not a `BlockDevice`, on purpose. That protocol is synchronous - `read` hands
/// back the bytes - and this driver is not: it takes a request, comes back, and
/// says the request finished later. The protocol still describes what a *client*
/// of the block service sees, which is what matters, because that is the shape
/// `FileSystem` is written against and the reason it can be tested over a slab of
/// host memory.
///
/// Legacy transports only, which is what this machine has. Version 1 puts the
/// queue at one physical page number and lets the guest choose the alignment;
/// version 2 hands over three separate addresses instead. Supporting one and
/// refusing the other is honest, and the refusal is a check rather than a
/// surprise.
///
/// Nothing it is told is believed on arrival. The window is checked for what it
/// is before a byte is written into it, the size is not taken until two readings
/// agree, every completion is measured against what was submitted, and every
/// request has five seconds. `VirtioRequestState` holds the rules for the last
/// two, in the ABI module and away from any register, so they can be tried
/// against sentences a device might say rather than against a device.
public struct VirtioBlock {

    /// Transport registers, from the virtio-mmio layout.
    private enum Register {
        static let magic            : UInt64 = 0x000
        static let version          : UInt64 = 0x004
        static let deviceID         : UInt64 = 0x008
        static let deviceFeatures   : UInt64 = 0x010
        static let deviceFeaturesSel: UInt64 = 0x014
        static let driverFeatures   : UInt64 = 0x020
        static let driverFeaturesSel: UInt64 = 0x024
        static let guestPageSize    : UInt64 = 0x028
        static let queueSel         : UInt64 = 0x030
        static let queueNumMax      : UInt64 = 0x034
        static let queueNum         : UInt64 = 0x038
        static let queueAlign       : UInt64 = 0x03C
        static let queuePFN         : UInt64 = 0x040
        static let queueNotify      : UInt64 = 0x050
        static let interruptStatus  : UInt64 = 0x060
        static let interruptAck     : UInt64 = 0x064
        static let status           : UInt64 = 0x070
        static let capacity         : UInt64 = 0x100
    }

    /// The handshake, one bit per step, written cumulatively.
    private enum Status {
        static let acknowledge: UInt32 = 1
        static let driver     : UInt32 = 2
        static let driverOK   : UInt32 = 4

        /// The device saying it has given up on itself. Not part of the
        /// handshake: it appears afterwards, and only re-reading the register
        /// finds it.
        static let needsReset : UInt32 = 64
        static let failed     : UInt32 = 128
    }

    /// What the interrupt status register says an interrupt was about. Two
    /// different events share one line, and telling them apart is the whole
    /// reason for reading it.
    private enum InterruptReason {
        static let usedBuffer  : UInt64 = 1
        static let configChange: UInt64 = 2
    }

    /// What the transport says it is: `virt` in ascii, then the device kind.
    ///
    /// Checked before anything is written, because everything after this point
    /// writes to registers whose meaning depends on both. A window carved at the
    /// wrong stride, or one naming a slot that holds a console, answers reads
    /// with numbers that are not nonsense - they are somebody else's numbers.
    private static let magicValue : UInt64 = 0x7472_6976
    private static let blockDevice: UInt64 = 2

    /// How long to wait for a reset to take, in counter ticks: a tenth of a
    /// second, which is a very long time for a register to settle.
    private static let resetCounts: UInt64 = 10

    /// How many requests may be out at once.
    ///
    /// Four, because three descriptors are one request and sixteen is the
    /// smallest power of two that holds four of those. Each also needs a page of
    /// data it does not share, which is what the buffer below is sized for.
    ///
    /// Getting here took the two things above this in the stack: the kernel had
    /// one reply slot per process, so a server that took a second request broke
    /// the first; and an interrupt could only be collected by parking on the
    /// line, so a driver could wait for work or wait for its disk and never
    /// both. Either one alone made this unreachable however many descriptors the
    /// ring had.
    public static let depth = 4

    /// The first descriptor of the chain for `slot`.
    ///
    /// The arithmetic is `VirtioQueueMap`'s and not this file's, so the rule a
    /// completion is checked against can be exercised without a device.
    private static func head(of slot: Int) -> UInt16 {
        UInt16(truncatingIfNeeded: VirtioQueueMap.head(of: slot))
    }

    private enum Descriptor {
        static let next : UInt16 = 1
        static let write: UInt16 = 2   // written by the device, not by us
        static let size : UInt64 = 16
    }

    /// Read is 0, write is 1 and flush is 4, in the header the device reads
    /// first.
    private enum Request {
        static let read : UInt32 = 0
        static let write: UInt32 = 1
        static let flush: UInt32 = 4
    }

    /// `VIRTIO_BLK_F_FLUSH`: the device has a write cache and will empty it when
    /// asked. The one optional feature this driver takes.
    private static let featureFlush: UInt32 = 1 << 9

    public let sectorSize: UInt64 = 512

    /// One request moves at most a page of sectors, which is the size of one
    /// slot's data area and the reason it is a page rather than a sector.
    public var maximumRun: UInt64 { Self.pageSize / sectorSize }

    /// Sixteen descriptors, not a guess: three are one request and the ring
    /// index arithmetic wants a power of two, so four requests need sixteen.
    private static let queueLength: UInt64 = VirtioQueueMap.queueLength(for: depth)

    private static let pageSize: UInt64 = 4096

    /// Where things sit in the one buffer the device and this process share.
    ///
    /// The layout is the transport's, not a choice. Legacy virtio puts the
    /// descriptors first, the available ring straight after them, and the used
    /// ring at the next multiple of the alignment the driver announced, which
    /// is why the used ring starts a page in with most of a page unused.
    private enum Offset {
        static let descriptors: UInt64 = 0
        static let available  : UInt64 = 256            // 16 bytes x 16 descriptors
        static let used       : UInt64 = 4096           // the announced alignment
        static let headers    : UInt64 = 8192           // 16 bytes per slot
        static let statuses   : UInt64 = 8192 + 256     // one byte per slot
        static let data       : UInt64 = 12288          // a page per slot

        static func header (of slot: Int) -> UInt64 { headers  + UInt64(slot) * 16 }
        static func status (of slot: Int) -> UInt64 { statuses + UInt64(slot) }
        static func payload(of slot: Int) -> UInt64 { data     + UInt64(slot) * 4096 }
    }

    /// Three pages of rings and headers, then one page of data per slot.
    private static let bufferPages: UInt64 = 3 + UInt64(depth)


    private let window   : UInt32
    private let interrupt: UInt32
    private let buffer   : DmaBuffer
    private let physical : UInt64

    /// The device's own count of 512-byte sectors, from its configuration space.
    ///
    /// Not a constant: a device may change its configuration and raise the line
    /// to say so, and a driver that read the size once would go on using a
    /// number the device has stopped meaning.
    public private(set) var sectorCount: UInt64

    /// What is out with the device, and every rule a completion has to satisfy.
    ///
    /// All of it lives in `VirtioRequestState`, which is in the ABI module and
    /// touches no register: that is what makes the answers to "what does this do
    /// when the ring says that" testable on a host instead of discoverable on a
    /// disk. Two arrays and three scattered checks used to live here.
    private var requests = VirtioRequestState()

    /// Counter ticks per second, read once. A deadline is arithmetic on the
    /// virtual counter, so the rate it runs at is a fact this needs at every
    /// submit and reads at none of them.
    private let frequency: UInt64

    /// The used-ring index this driver has already seen. A request is complete
    /// when the device moves it, and comparing against the last one seen is the
    /// only way to tell a fresh completion from a stale ring.
    private var lastUsed: UInt16 = 0

    /// Set the first time the device stops making sense, and never cleared.
    ///
    /// A timeout, a used ring that disagrees with what was submitted, or the
    /// device saying it needs a reset. From then on every request is refused
    /// where it is made rather than waited on: one dead device is a dead disk,
    /// and a dead disk answered quickly is a machine that still boots and can
    /// say what happened.
    public private(set) var dead = false

    /// Whether the device negotiated a way to be asked to empty its write cache.
    ///
    /// The only durability fact this driver has. `false` is not the opposite
    /// claim, it is no claim, so it becomes `unknown` below and not
    /// `onCompletion`.
    private let cached: Bool

    /// What a completed write on this device has achieved.
    ///
    /// Two answers out of three, and the missing one is the correction. The
    /// negotiated feature is a promise this driver can hold the device to: it
    /// takes flush requests, so a flush is what makes an order. The *absence* of
    /// the feature used to be read as `onCompletion`, on the strength of the
    /// specification saying such a device has no volatile write cache - which is
    /// a sentence in a document and not a thing this driver can check. A promise
    /// nobody made is `unknown`, and no reading around the negotiation turns it
    /// into the strongest claim on the list.
    public var durability: BlockDurability { cached ? .onFlush : .unknown }


    // MARK: - Bring-up

    /// Resets the device, takes ownership of it, hands it one queue and tells
    /// it the driver is ready.
    ///
    /// `nil` when the transport is not a legacy one, when the buffer cannot be
    /// allocated, or when the device offers a queue too short to hold a request.
    /// Every one of those leaves the device marked failed rather than half
    /// configured, because a device left in the middle of the handshake is a
    /// device the next driver cannot reset cleanly.
    public init?(window: UInt32, interrupt: UInt32) {

        // What this window is, before a byte is written into it. A window is a
        // physical range somebody else carved and handed over, so "it is a legacy
        // virtio-mmio block transport" is three facts to check and not an
        // assumption to make: the magic says the layout, the version says which
        // layout, and the device id says what is behind it.
        guard deviceRead(handle: window, offset: Register.magic) == Self.magicValue,
              deviceRead(handle: window, offset: Register.version) == 1,
              deviceRead(handle: window, offset: Register.deviceID) == Self.blockDevice
        else { return nil }

        let buffer = dmaAlloc(device: window, pageCount: Self.bufferPages)
        guard buffer.isValid else { return nil }

        let physical = dmaPhysical(handle: buffer.handle)
        guard physical != UInt64.max else { return nil }

        self.window    = window
        self.interrupt = interrupt
        self.buffer    = buffer
        self.physical  = physical
        self.frequency = readCounterFrequency()

        // Reset first. The device may have been left configured by whatever ran
        // before this, and there is no way to inspect that, only to undo it.
        //
        // And then wait for it, bounded. A reset is not instantaneous on a real
        // transport and there is no interrupt for it, so the only way to know it
        // took is to look at the register until it reads zero - which is also the
        // one place a device that is not going to answer at all can be caught
        // before it has been handed a queue.
        _ = deviceWrite(handle: window, offset: Register.status, value: 0)

        guard Self.acceptedReset(window, frequency: self.frequency) else { return nil }

        var status = Status.acknowledge
        _ = deviceWrite(handle: window, offset: Register.status, value: status)

        status |= Status.driver
        _ = deviceWrite(handle: window, offset: Register.status, value: status)

        // One optional feature is taken, and only one: the ability to ask the
        // device to empty its write cache. A feature accepted is a promise to
        // honour it in every path afterwards, and the promise this one makes is
        // small - that flush requests may arrive - while what it buys is the
        // only barrier the layer above has.
        //
        // A device that does not offer it is not a device with no cache: it is a
        // device that has promised nothing, and `durability` says so. Nothing
        // above may write a file system through one of those.
        _ = deviceWrite(handle: window, offset: Register.deviceFeaturesSel, value: 0)
        let offered = deviceRead(handle: window, offset: Register.deviceFeatures)

        let taken = UInt32(truncatingIfNeeded: offered) & Self.featureFlush
        self.cached = taken != 0

        _ = deviceWrite(handle: window, offset: Register.driverFeaturesSel, value: 0)
        _ = deviceWrite(handle: window, offset: Register.driverFeatures, value: taken)

        // Legacy addresses the queue by page number, so it has to be told what
        // this guest calls a page before it is told which one.
        _ = deviceWrite(
            handle: window,
            offset: Register.guestPageSize,
            value : UInt32(Self.pageSize)
        )

        _ = deviceWrite(handle: window, offset: Register.queueSel, value: 0)

        guard deviceRead(handle: window, offset: Register.queueNumMax) >= Self.queueLength else {
            _ = deviceWrite(handle: window, offset: Register.status, value: Status.failed)
            return nil
        }

        _ = deviceWrite(
            handle: window,
            offset: Register.queueNum,
            value : UInt32(Self.queueLength)
        )
        _ = deviceWrite(
            handle: window,
            offset: Register.queueAlign,
            value : UInt32(Self.pageSize)
        )
        _ = deviceWrite(
            handle: window,
            offset: Register.queuePFN,
            value : UInt32(truncatingIfNeeded: physical / Self.pageSize)
        )

        status |= Status.driverOK
        _ = deviceWrite(handle: window, offset: Register.status, value: status)

        // Read after the handshake, not before: configuration space is only
        // guaranteed to mean anything once the device has been acknowledged. And
        // only once it has settled: an unstable or zero size is a device to
        // refuse rather than a number to bound requests against.
        guard let capacity = VirtioCapacity.settled({ Self.capacityReading(window) })
        else {
            _ = deviceWrite(handle: window, offset: Register.status, value: Status.failed)
            return nil
        }

        self.sectorCount = capacity
    }


    /// Waits, bounded, for the device to show that the reset took.
    ///
    /// A spin and not a sleep, because this is bring-up: there is nothing else
    /// for this process to do and a scheduler round trip per look would make the
    /// boot slower for no gain. Bounded because a device that never clears its
    /// status is a device to give up on, and spinning on one for ever is the
    /// failure this whole feature is about.
    private static func acceptedReset(_ window: UInt32, frequency: UInt64) -> Bool {

        let budget   = frequency == 0 ? 1 : frequency / Self.resetCounts
        let deadline = readVirtualCounter() &+ budget

        while true {
            if deviceRead(handle: window, offset: Register.status) == 0 { return true }

            if VirtioRequestState.reached(deadline, at: readVirtualCounter()) {
                return false
            }
        }
    }


    /// One reading of the device's sector count, both halves.
    ///
    /// Whether a reading is worth believing is `VirtioCapacity`'s question, and
    /// it is asked over several of these. This function only reads.
    private static func capacityReading(_ window: UInt32) -> UInt64 {

        let low  = deviceRead(handle: window, offset: Register.capacity)
        let high = deviceRead(handle: window, offset: Register.capacity + 4)

        return (high << 32) | (low & 0xFFFF_FFFF)
    }


    // MARK: - Requests

    /// What kind of request a slot is carrying.
    ///
    /// The kind itself belongs with the state that records it, so it lives in the
    /// ABI module; what stays here is the one thing that is about this transport
    /// and not about the bookkeeping - the number the header wants.
    public typealias Kind = VirtioRequestState.Kind

    private static func code(of kind: Kind) -> UInt32 {
        switch kind {
            case .read : Request.read
            case .write: Request.write
            case .flush: Request.flush
        }
    }


    /// Where a slot's data page starts, for a caller filling it before a write
    /// or emptying it after a read.
    ///
    /// The copy in and out is unavoidable rather than lazy: the device reads from
    /// memory it was handed the physical address of, and that is this buffer and
    /// no other. Handing it a client's own page instead needs an IOMMU, pinning,
    /// and a lifetime rule for pages a device is looking at.
    public func page(of slot: Int) -> UnsafeMutableRawPointer {
        at(Offset.payload(of: slot))
    }

    /// A slot nobody is using, or nil when all four are out with the device.
    public func freeSlot() -> Int? { requests.freeSlot() }

    /// Whether anything is out with the device at all.
    public var idle: Bool { requests.idle }

    /// The most requests that were ever out at once.
    public var highWater: Int { requests.highWater }


    /// Hands one request to the device and comes straight back.
    ///
    /// The whole point of the restructuring: this used to wait for the interrupt
    /// before returning, which is why the server it runs inside could serve one
    /// client at a time and no descriptor past the first was ever used. Now the
    /// waiting happens in the server's own `receive`, where its clients are
    /// waiting too, and `collect` is called when the device speaks.
    ///
    /// For a write, fill `page(of:)` first. For a read, read it after the
    /// completion and not before.
    public mutating func submit(
        _ kind: Kind,
        sector: UInt64,
        count : UInt64,
        into slot: Int
    ) -> BlockStatus {

        guard !dead else { return .deviceRefused }
        guard slot >= 0, slot < Self.depth, !requests.isBusy(slot) else {
            return .deviceRefused
        }

        if kind != .flush {
            // The same bound `BlockDevice.holds` applies to a client, applied
            // here to a driver that no longer conforms to it: the range check is
            // shared arithmetic, not a thing each layer invents.
            guard BlockRange.fits(
                count,
                from : sector,
                in   : sectorCount,
                limit: maximumRun
            ) else {
                return count > maximumRun ? .tooLong : .outOfRange
            }
        }

        // A read hands its page to a client, so the page starts as zeroes rather
        // than as whatever the last request through this slot left in it. The
        // length check on the completion already refuses a short read, so nothing
        // here is load-bearing on its own - which is the point of doing it: two
        // independent reasons the client cannot be handed bytes the device never
        // wrote, and the cost is one page of stores against a disk round trip.
        if kind == .read {
            page(of: slot).initializeMemory(
                as      : UInt8.self,
                repeating: 0,
                count   : Int(Self.pageSize)
            )
        }

        let header = Offset.header(of: slot)

        write32(header,     Self.code(of: kind))
        write32(header + 4, 0)
        write64(header + 8, kind == .flush ? 0 : sector)

        // Not a status the device uses, so seeing it again means the device
        // never wrote one rather than having written success. Named once, in the
        // state that checks it, so the sentinel and its check cannot drift.
        write8(Offset.status(of: slot), VirtioRequestState.unwritten)

        let head = Self.head(of: slot)

        if kind == .flush {
            // Two descriptors and no data: a flush carries nothing but its own
            // header, which is what makes it a barrier rather than a transfer.
            describe(UInt64(head), at: header, length: 16,
                     flags: Descriptor.next, next: head &+ 2)

        } else {
            let data = kind.deviceWrites
                ? Descriptor.next | Descriptor.write
                : Descriptor.next

            describe(UInt64(head), at: header, length: 16,
                     flags: Descriptor.next, next: head &+ 1)

            describe(UInt64(head &+ 1), at: Offset.payload(of: slot),
                     length: UInt32(truncatingIfNeeded: count * sectorSize),
                     flags : data, next: head &+ 2)
        }

        describe(UInt64(head &+ 2), at: Offset.status(of: slot),
                 length: 1, flags: Descriptor.write, next: 0)

        // Recorded before the device is told, and that order is the protocol: the
        // doorbell may be answered before the store after it retires, so a slot
        // written down afterwards is a completion arriving for a request nothing
        // remembers.
        //
        // The deadline is set here and never touched again. An interrupt for
        // somebody else, or a configuration change, does not buy a stuck request
        // more time: it was given five seconds when it was submitted and that is
        // what it has.
        guard requests.begin(
            slot        : slot,
            kind        : kind,
            sectors     : UInt32(truncatingIfNeeded: count),
            payloadBytes: UInt32(truncatingIfNeeded: count * sectorSize),
            deadline    : VirtioRequestState.deadline(
                from     : readVirtualCounter(),
                frequency: frequency
            )
        ) else { return .deviceRefused }

        guard offer(head) else {
            requests.abandon(slot)
            return .deviceRefused
        }

        return .ok
    }


    /// One request that has come back, or nil when none has.
    ///
    /// Called after the device raises its line, and called in a loop: one
    /// interrupt may cover several completions, because the device is free to
    /// finish two requests and signal once. A driver that read only one entry per
    /// interrupt would leave the other outstanding for ever.
    ///
    /// The slot is *not* released here. Its data page still holds what the device
    /// wrote, and releasing it before the caller has read that page would hand
    /// the page to the next request.
    public mutating func collect() -> (slot: Int, count: UInt32, status: BlockStatus)? {

        guard !dead else { return nil }

        let completed = read16(Offset.used + 2)
        guard completed != lastUsed else { return nil }

        // The index moving is the device saying it has finished. Reading what it
        // finished *with* - the ring entry, the status byte, the sectors it just
        // wrote into the data page - has to happen after that, and this is what
        // makes it so rather than leaving it to luck.
        dmaReadBarrier()

        // `vring_used_elem` is an id and a length, eight bytes each entry, after
        // the flags and index words at the front of the ring. Both halves are
        // read now: the length used to be left where the device put it, so a
        // device that completed a read having written five bytes had a whole page
        // handed to a client.
        let ring   = UInt64(lastUsed % UInt16(Self.queueLength))
        let id     = read32(Offset.used + 4 + ring * 8)
        let length = read32(Offset.used + 8 + ring * 8)

        // Every check in one call, and the status byte fetched from inside it,
        // because which byte to read depends on the slot the id decodes to. A
        // caller cannot do four of the five and forget the fifth.
        let base = buffer.address

        let verdict = requests.complete(
            id     : id,
            length : length,
            advance: completed &- lastUsed
        ) { Self.statusByte(base: base, slot: $0) }

        switch verdict {
            case .fault(let fault):
                // Not this request refused: the device has said something no
                // device can truthfully say, so it is reset and everything out
                // with it is abandoned. Nothing is copied anywhere on this path.
                stop(Self.why(fault))
                return nil

            case .accept(let slot, let sectors, let failed):
                lastUsed = lastUsed &+ 1
                return (slot, sectors, failed ? .deviceRefused : .ok)
        }
    }


    /// One slot's status byte, addressed from the buffer's base.
    ///
    /// Static, and reached through the base rather than through `read8`, because
    /// it is called from inside a closure handed to the state that is being
    /// mutated: touching `self` there is two overlapping accesses to the same
    /// value, which is a compile error and would be a real one.
    private static func statusByte(base: UInt64, slot: Int) -> UInt8 {
        UnsafeRawPointer(bitPattern: UInt(base + Offset.status(of: slot)))!
            .load(as: UInt8.self)
    }


    /// What to print when a device has said something impossible.
    private static func why(_ fault: VirtioRequestState.Fault) -> StaticString {
        switch fault {
            case .unknownChain:
                "the device finished a chain that was never submitted"

            case .notOutstanding:
                "the device finished a request twice"

            case .wrongLength:
                "the device reported a length no completion of that kind has"

            case .statusNotWritten:
                "the device finished a request without writing its status"

            case .tooManyCompletions:
                "the device completed more than was asked of it"
        }
    }


    // MARK: - Time

    /// How many scheduler ticks to wait for the device: nil when nothing is out
    /// with it, so there is nothing to wait for.
    ///
    /// Rounded up, and never to nothing, so that when the wait ends the deadline
    /// it was computed from really has passed. A wait rounded down is a poll.
    public func waitTicks() -> UInt32? {

        guard let counts = requests.timeRemaining(at: readVirtualCounter()) else {
            return nil
        }

        return VirtioRequestState.schedulerTicks(
            counts             : counts,
            frequency          : frequency,
            millisecondsPerTick: SchedulerABI.millisecondsPerTick
        )
    }


    /// Whether anything out with the device has run out of time.
    public var late: Bool { requests.timeRemaining(at: readVirtualCounter()) == 0 }


    /// Takes the device out of service for a reason that came from this side of
    /// the transport rather than from the device.
    ///
    /// The reason is the caller's because the caller is the one who knows it: a
    /// wait that could not be bounded, or a server that has lost count of what it
    /// owes. Either way the reset is not politeness - the device's descriptors are
    /// still programmed into the queue, and the reset is what makes it let go of
    /// memory this process is about to reuse.
    public mutating func giveUp(_ why: StaticString) {
        stop(why)
    }


    /// Gives up on the device when something it was given has run out of time.
    ///
    /// `true` when the device was taken out of service, which is the caller's cue
    /// to answer everybody who was waiting. One late request condemns the whole
    /// device rather than only itself: a disk that has silently dropped one
    /// request has not shown that it will honour the next.
    public mutating func giveUpOnLate() -> Bool {

        guard !dead, late else { return false }

        stop("the device did not answer in time")
        return true
    }


    /// Reads the device's own account of an interrupt and says what it means.
    ///
    /// Every way out that is not a completion used to go through the wait loop
    /// inside `submit`; now it is here, because the interrupt arrives at the
    /// server's `receive` and not inside a transfer.
    public mutating func acknowledge(lines: UInt32) -> Bool {

        guard !dead else { return false }

        // The device is quietened first and the line unmasked second. The other
        // order re-enters the handler for an interrupt already being serviced.
        let reason = deviceRead(handle: window, offset: Register.interruptStatus)
        _ = deviceWrite(
            handle: window,
            offset: Register.interruptAck,
            value : UInt32(truncatingIfNeeded: reason)
        )
        _ = irqAck(handle: interrupt, bits: UInt64(lines))

        // Asked on every interrupt, because it is the only place the device gets
        // to say it has given up on itself, and it says it long after the
        // handshake that everything else was checked in.
        let health = deviceRead(handle: window, offset: Register.status)

        guard health & UInt64(Status.needsReset) == 0 else {
            stop("the device asked to be reset")
            return false
        }

        if reason & InterruptReason.configChange != 0, !resized() { return false }

        return reason & InterruptReason.usedBuffer != 0
    }


    /// Takes the device's new size, or refuses to carry on with it.
    ///
    /// A size that moves while requests are out cannot be reconciled: those
    /// requests were bounds-checked against the old number and are already
    /// programmed into the queue, so there is no honest answer about what they
    /// are now reading. Idle, the new size is taken - but only once it has
    /// settled, because a bound checked against a number read mid-change is not
    /// a bound.
    private mutating func resized() -> Bool {

        guard requests.idle else {
            stop("the device changed size with requests outstanding")
            return false
        }

        let handle = window

        guard let settled = VirtioCapacity.settled({ Self.capacityReading(handle) }) else {
            stop("the device would not settle on a size")
            return false
        }

        sectorCount = settled
        return true
    }


    /// Gives up on everything outstanding, because the device has.
    ///
    /// Answers the slots that were out, so the server can tell their callers
    /// rather than leaving them parked on a disk that is never going to answer.
    /// This is what a queue owes that one request in flight did not: with one, the
    /// single caller was the one already inside the failing call.
    public mutating func abandonOutstanding() -> InlineArray<4, Bool> {
        requests.abandonAll()
    }


    /// Offers a chain to the device and rings the doorbell.
    ///
    /// Three barriers, and each one is at a point where ownership of memory
    /// changes hands. They are not belt and braces: the ring lives in Normal
    /// Non-Cacheable memory, which is an attribute about *visibility* - a device
    /// that never looks in a cache sees what was written without maintenance -
    /// and Normal memory may be reordered freely by the CPU and by the compiler.
    /// Nothing about the mapping puts these stores in the order they are written
    /// in, and the whole protocol here is an order.
    private mutating func offer(_ head: UInt16) -> Bool {

        guard !dead else { return false }

        let index = read16(Offset.available + 2)
        let ring = UInt64(index % UInt16(Self.queueLength))
        write16(Offset.available + 4 + ring * 2, head)

        // Everything the device is about to be sent to look at - the
        // descriptors, the header, the status byte, the data - before the one
        // word that tells it to look. This is the barrier VirtIO names: before
        // ownership passes through an index.
        dmaWriteBarrier()

        write16(Offset.available + 2, index &+ 1)

        // And the index before the doorbell, which is a different memory type
        // again: the ring is Normal Non-Cacheable and the notify register is
        // Device. Nothing orders a store to one against a store to the other.
        //
        // The doorbell happens to go through a syscall, and an exception entry
        // is a barrier of its own - which is exactly why this line is here and
        // not left implied. A driver that is correct because of where the
        // syscall boundary happens to fall is correct by accident.
        dmaWriteBarrier()

        _ = deviceWrite(handle: window, offset: Register.queueNotify, value: 0)

        return true
    }


    /// Asks for this device's line to arrive as a message on `endpoint`.
    ///
    /// The other half of what makes a queue usable. Without it the only way to
    /// hear from the device is `irqWait`, which parks this process on the line -
    /// and a process parked on a line is not in `receive`, so the server it lives
    /// in can take no request while the disk is working. One `receive` now
    /// answers a client or the disk, whichever speaks first.
    public func listen(on endpoint: UInt32) -> Bool {
        irqBind(handle: interrupt, endpoint: endpoint)
    }


    /// Takes the device out of service, for good.
    ///
    /// Reset and not `FAILED`, and the difference matters: `FAILED` is a polite
    /// note that the driver has given up, and a device that has stopped
    /// answering is not reading notes. Reset is the one write that makes it let
    /// go of the descriptors it was given - which point into a buffer this
    /// process is about to reuse for something else.
    ///
    /// Nothing is retried and nothing is re-initialised. Whether this machine
    /// should try again with this device is a decision, and it is not one a
    /// driver whose device just stopped making sense is in a position to take.
    private mutating func stop(_ why: StaticString) {

        guard !dead else { return }
        dead = true

        _ = deviceWrite(handle: window, offset: Register.status, value: 0)

        print("[ DISK  ] ", terminator: "")
        print(why, terminator: "")
        print(", the disk is out of service")
    }


    /// Fills descriptor `slot` with a buffer the device can reach.
    private func describe(
        _ slot: UInt64,
        at     offset: UInt64,
        length: UInt32,
        flags : UInt16,
        next  : UInt16
    ) {
        let base = Offset.descriptors + slot * Descriptor.size

        write64(base,      physical + offset)
        write32(base + 8,  length)
        write16(base + 12, flags)
        write16(base + 14, next)
    }


    // MARK: - The shared buffer

    // Plain stores into memory the device also reads. It is mapped Normal
    // Non-Cacheable, which is what makes a write here visible over there
    // without any cache maintenance of our own - and that is the whole of what
    // the attribute buys.
    //
    // It does not buy ordering. Normal memory may be reordered by the CPU, and
    // these are ordinary Swift stores so the compiler may reorder them too.
    // Wherever the order is the protocol - which in a virtqueue is everywhere -
    // it is `dmaWriteBarrier` and `dmaReadBarrier` in `submit` that provide it,
    // and nothing here.

    private func at(_ offset: UInt64) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(bitPattern: UInt(buffer.address + offset))!
    }

    private func write8 (_ o: UInt64, _ v: UInt8)  { at(o).storeBytes(of: v, as: UInt8.self)  }
    private func write16(_ o: UInt64, _ v: UInt16) { at(o).storeBytes(of: v, as: UInt16.self) }
    private func write32(_ o: UInt64, _ v: UInt32) { at(o).storeBytes(of: v, as: UInt32.self) }
    private func write64(_ o: UInt64, _ v: UInt64) { at(o).storeBytes(of: v, as: UInt64.self) }

    private func read8 (_ o: UInt64) -> UInt8  { at(o).load(as: UInt8.self)  }
    private func read16(_ o: UInt64) -> UInt16 { at(o).load(as: UInt16.self) }
    private func read32(_ o: UInt64) -> UInt32 { at(o).load(as: UInt32.self) }
}
