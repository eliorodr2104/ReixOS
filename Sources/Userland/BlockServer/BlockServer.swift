//
//  BlockServer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import Reix

/// The one process that drives the disk, and the only one that needs to.
///
/// It holds three things nobody else does: the window on the transport's
/// registers, the interrupt line it raises, and the buffer the device transfers
/// through. Everything above it names sectors and gets bytes, which is the
/// entire reason this exists.
///
/// The sectors move through a page each client shares with it, one per client,
/// handed over at `attach`. A request is a message that names sectors; the
/// bytes are already where both sides can see them.
///
/// It also holds the volume, which is the one piece of policy in here: one
/// process claims the disk with `mount` and is thereafter the only one whose
/// writes are carried out. Everybody else may look, and only while nobody has
/// claimed it. See `BlockAccess` for the rule itself.
public struct BlockServer: Service {

    /// It publishes nothing.
    ///
    /// A name is a lookup anybody may do, and this is the whole disk. So the
    /// endpoint goes to the process that started this one, once, and travels
    /// from there by being handed over rather than by being found.
    public static let manifest = ServiceManifest(provides: .parent)

    /// How many clients at once. Small on purpose: each one costs a mapped page
    /// here, and the file system is going to be the only client that matters.
    private static let capacity = 8

    private static let pageSize: UInt64 = 4096

    /// The largest window a client may attach. A client that asks for more is
    /// asking this process to map it, and the answer is no.
    private static let maximumPages: UInt32 = 4

    private let endpoint: UInt32
    private var device  : VirtioBlock

    /// The window each client attached, one slot each.
    ///
    /// `ShmAttachment.Slot` and not a bare optional, and the difference is the
    /// replacement rule: `install` hands back whatever it displaced, in one
    /// store, so there is no moment at which a slot is empty and no way to
    /// overwrite a window without being given the old one to unmap. It carries a
    /// fact four parallel arrays could not: *which* attachment of that client
    /// this is. See `ShmAttachment`.
    private var attachments: InlineArray<8, ShmAttachment.Slot> = InlineArray(
        repeating: ShmAttachment.Slot()
    )

    /// Where attachment numbers come from. One source for the whole server, so
    /// two clients can never be handed the same one either.
    private var epochs = ShmAttachment.Epochs()

    /// Who is owed what: the requests out with the device and the completions
    /// finished and not yet collected.
    ///
    /// The table that a queue costs and one request in flight did not. A request
    /// is answered when its slot completes, and by then the loop has been round
    /// several times and may be holding other requests too, so who asked for what
    /// cannot live on the stack of the call that took it - and every entry
    /// carries the attachment it was made against. See `BlockRequests`.
    private var requests = BlockRequests()

    /// Set when a completion had nowhere to be recorded.
    ///
    /// Not handled where it is found, on purpose: the reaction is to fail
    /// everything outstanding, and failing an outstanding request is itself a
    /// thing that records a completion. A flag read once round the loop is what
    /// keeps that from recurring into itself.
    private var wedged = false

    /// Clients parked in `collect` with nothing finished for them yet.
    ///
    /// The call is held rather than refused, which is what makes a client's
    /// collect loop a loop instead of a poll. Answered the moment one of its
    /// transfers comes back.
    private var collecting: InlineArray<8, Bool> = InlineArray(repeating: false)

    /// How many requests were refused because every slot was out.
    ///
    /// A fixed depth with no way to see it fill up is a depth whose value is a
    /// guess nobody can check.
    private var saturations: UInt32 = 0

    /// Messages that wore the kernel's interrupt label and came from a process.
    ///
    /// It must stay at zero. A number here is somebody having tried to make this
    /// process read the transport's registers and acknowledge an interrupt line
    /// on their behalf, which is why the line it prints is one the scenario
    /// matrix forbids rather than merely notes.
    private var forgedInterrupts: UInt32 = 0

    /// The deepest each of the two queues has been said to have reached, so every
    /// rise is said once. See `noteDepth`.
    private var reportedDepth = 0
    private var reportedDeviceDepth = 0

    /// Who is holding the volume, if anybody is.
    ///
    /// One process, not one slot: this outlives an attachment on purpose, so a
    /// client that drops its window does not thereby hand the disk to whoever
    /// asks next. It is given up three ways, and only three: the holder says so
    /// (`unmount`), the holder attaches again and is therefore starting over,
    /// or a warden says the holder is gone (`reclaim`).
    ///
    /// A dead holder's *window* is taken back on its own now, by asking whether
    /// the identity still runs (`sweepDeadClients`). The claim is not, and that
    /// is the line: a window is a resource this server lent out, the volume is an
    /// authority somebody else granted, and only a warden speaks for it. See
    /// `reclaim`.
    private var holder: UInt32? = nil

    public var serviceEndpoint: UInt32 { endpoint }


    public init(environment: Environment, endpoint: UInt32) {

        self.endpoint = endpoint

        guard let window = environment.device,
              let line   = environment.interrupt
        else {
            print("[ DISK  ] no transport window or no interrupt line")
            exit(code: 1)
        }

        guard let device = VirtioBlock(window: window, interrupt: line) else {
            print("[ DISK  ] the block device refused to come up")
            exit(code: 1)
        }

        self.device = device

        // From here the disk speaks on the same endpoint the clients do, which
        // is what lets this loop hold a request open while the disk works on it.
        // Refusing to come up without it is deliberate: a driver that silently
        // fell back to waiting on the line would serve one request at a time and
        // look exactly like one that was pipelining.
        guard device.listen(on: endpoint) else {
            print("[ DISK  ] the interrupt line could not be bound to the service endpoint")
            exit(code: 1)
        }

        print("[ DISK  ] serving ", terminator: "")
        printDec(device.sectorCount, terminator: "")
        print(" sectors of ", terminator: "")
        printDec(device.sectorSize, terminator: "")
        print(" bytes")
    }


    /// The receive loop, with a deadline on it.
    ///
    /// The default loop parks in `receive` until something arrives, which is
    /// right for a server whose only news comes from clients. It is wrong here:
    /// the other half of the news is a device, and a device that stops answering
    /// says nothing at all. Waiting for that is waiting for ever, and the process
    /// that never wakes is the one holding the disk.
    ///
    /// So the wait is bounded by whatever is out with the device, and the bound
    /// comes from the request that was submitted first. When it runs out, the
    /// device is reset and everybody waiting is answered - which is what a queue
    /// owes and one request in flight did not, because there the caller was
    /// already inside the failing call.
    public mutating func run() {

        var fruitless = 0

        while true {

            // Before waiting again, and not only after a wait that ended in
            // nothing: a message may arrive for one client while another
            // client's request quietly runs out of time.
            if device.giveUpOnLate() {
                failEverybody()
                continue
            }

            var request: ReceivedMessage

            if let ticks = device.waitTicks() {
                guard let arrived = receive(handle: endpoint, timeout: ticks) else {
                    // Either the deadline passed - in which case the check at the
                    // top of the loop is about to fire - or the kernel could not
                    // arm the wait at all, which is the one way this becomes a
                    // spin. Bounded rather than trusted: a wait that cannot be
                    // bounded is a wait this server must not take.
                    fruitless &+= 1

                    if fruitless > Self.fruitlessWaits {
                        device.giveUp("the wait for the device could not be bounded")
                        failEverybody()
                        fruitless = 0
                    }

                    continue
                }

                request = arrived

            } else {
                // Nothing is out with the device, so there is no deadline to
                // keep and nothing to wake up for except a client.
                request = receive(handle: endpoint)
            }

            fruitless = 0

            if let fired = request.kernelInterrupt {
                handle(interrupt: fired)

            } else if InterruptNotification.names(request.message.tag) {
                // The label of a device and the identity of a process. Nothing
                // is done with it, and it is said once.
                noteForgery()

            } else if let operation = BlockOperation(rawValue: request.message.tag.label) {
                handle(operation, request: &request)
                noteDepth()
            }

            if wedged { stopForBookkeeping() }

            if let grantedCap = request.takeGrant() { _ = capDrop(grantedCap) }
        }
    }

    /// How many timed waits may end in nothing before the wait itself is the
    /// problem.
    private static let fruitlessWaits = 64


    /// Says once that somebody sent this process a message dressed as its device.
    private mutating func noteForgery() {

        if forgedInterrupts < UInt32.max { forgedInterrupts += 1 }
        guard forgedInterrupts == 1 else { return }

        print("[ DISK  ] a client sent a message dressed as the device, ignored")
    }


    /// Says how deep each queue has been, as it gets deeper.
    ///
    /// Two numbers, because there are two questions and only one of them has a
    /// stable answer.
    ///
    /// `queue depth` is how many requests one client had accepted and not yet
    /// collected. A name is taken when a request is accepted and given back when
    /// the answer is collected, so a rise here means a client asked for a second
    /// thing before taking delivery of the first, which is what pipelining is. It
    /// depends on the client's code and on nothing else, which is why this is the
    /// one the matrix asserts.
    ///
    /// `device depth` is how many were out *with the device* at once, and it is a
    /// race. QEMU can finish a one-block read before the second submission
    /// reaches it, and then the driver never holds two however hard the client
    /// pipelines. It was asserted for a while and failed about one run in three
    /// at 4 MiB, saying the queue was shallow when what had happened was that the
    /// disk was quick. It is printed and not asserted.
    ///
    /// The matrix reads both with a post-check rather than requiring one as a
    /// marker: which line of another process's output these land between is a
    /// race, and a marker chain is an ordered subsequence.
    private mutating func noteDepth() {

        if requests.deepestHeld > reportedDepth {
            reportedDepth = requests.deepestHeld

            print("[ DISK  ] queue depth ", terminator: "")
            printDec(UInt64(reportedDepth))
        }

        if device.highWater > reportedDeviceDepth {
            reportedDeviceDepth = device.highWater

            print("[ DISK  ] device depth ", terminator: "")
            printDec(UInt64(reportedDeviceDepth))
        }
    }


    /// Serves one request, having first checked who is asking.
    ///
    /// Three things before the operation is looked at at all. Identity zero is
    /// not a process - the kernel writes it for a message that came from none -
    /// so a request wearing it is one no state here can be keyed on, and it is
    /// the only way an operation label and a kernel-origin message could meet. A
    /// granted page is part of exactly one operation, so anything else arriving
    /// with one is a client trying to make this process map something no request
    /// of that shape asked for. And the badge, which decides everything else.
    public mutating func handle(
        _ operation: BlockOperation,
          request  : inout ReceivedMessage
    ) {
        guard request.identity != InterruptNotification.kernelIdentity else { return }

        // Refused rather than served with a stranger's grant in hand. The
        // receive loop gives the grant back.
        guard operation == .attach || request.grantedCap == nil else {
            _ = reply(message: BlockOperation.answer(.notAuthorised))
            return
        }

        // The badge comes off the capability it arrived through and the holder
        // out of this process's own memory: neither is the caller's to say.
        let allowed = BlockAccess.check(
            operation,
            session: request.session,
            holder : holder,
            caller : request.identity
        )

        // Only the operations that touch the disk can be refused here.  A
        // one-way `begin` has no reply rendezvous: when it has a real attached
        // tag, its access refusal must be the tagged result `collect` returns.
        // The other operations are calls and answer their status directly.
        guard allowed == .ok else {
            if operation == .begin {
                refuseBegin(request, status: allowed)
            } else {
                _ = reply(message: BlockOperation.answer(allowed))
            }
            return
        }

        switch operation {
            case .attach:
                attach(&request)

            case .geometry:
                guard attachment(of: request.identity) != nil else {
                    _ = reply(message: BlockOperation.answer(.notAttached))
                    return
                }

                _ = reply(message: BlockOperation.geometry(
                    sectorSize : UInt32(truncatingIfNeeded: device.sectorSize),
                    sectorCount: device.sectorCount,
                    durability : device.durability
                ))

            case .read, .write:
                // No reply here when the request was accepted. The caller stays
                // parked and hears back from `completed`, which is the whole of
                // what pipelining is: this loop goes round and takes the next
                // request while the disk is still working on this one.
                if let refusal = start(operation, request: request) {
                    _ = reply(message: BlockOperation.answer(refusal))
                }

            case .begin:
                // `begin` is deliberately one-way. Its refusal, if any, is a
                // tagged completion `collect` takes; replying here would make
                // a fast device complete each request before the next admission
                // round trip ended and silently collapse the queue to depth one.
                begin(request)

            case .collect:
                collect(request)

            case .flush:
                if let refusal = startFlush(request) {
                    _ = reply(message: BlockOperation.answer(refusal))
                }

            case .mount:
                holder = request.identity
                _ = reply(message: BlockOperation.answer(.ok))

            case .unmount:
                holder = nil
                _ = reply(message: BlockOperation.answer(.ok))

            case .reclaim:
                // A holder that has gone left more behind than a claim: its
                // window is still mapped in this process and its page still
                // granted to it. Letting go of the claim alone would trade a
                // stuck disk for a leaked page.
                //
                // No sector is touched here, and that matters as much as the
                // rest: whatever the dead holder wrote stays written, and
                // whatever it marked on the disk stays marked, so the next
                // process to mount finds the disk exactly as the crash left it.
                if let gone = holder, let slot = slot(for: gone) {
                    release(slot: slot)
                }

                holder = nil
                _ = reply(message: BlockOperation.answer(.ok))
        }
    }


    /// Moves one run of sectors between the disk and the caller's window.
    ///
    /// The window is checked against the run as well as the device, and today
    /// the two say the same thing: the smallest window a client may attach is a
    /// page, and a page is exactly the driver's longest run. The check earns its
    /// keep the moment either of those constants moves, and until then it is
    /// two lines that cannot be observed to fire. Worth knowing rather than
    /// worth removing.
    private mutating func start(
        _ operation: BlockOperation,
          request  : ReceivedMessage
    ) -> BlockStatus? {

        guard let held = attachment(of: request.identity) else { return .notAttached }

        let client = held.slot
        let window = held.attachment

        let count  = UInt64(request.message.words[0])
        let sector = BlockOperation.sector(of: request.message)

        guard count > 0 else { return .ok }
        guard count <= device.maximumRun,
              window.covers(0, count * device.sectorSize)
        else { return .tooLong }

        guard let free = device.freeSlot() else { return saturated() }

        // Before a byte is copied and before the device is told anything. See
        // `BlockRequests.State`.
        guard requests.reserve(free, BlockRequests.Pending(
            client    : client,
            identity  : request.identity,
            epoch     : window.epoch,
            tag       : nil,
            copiesBack: operation != .write
        )) else { return .queueFull }

        let writing = operation == .write

        if writing {
            device.page(of: free).copyMemory(
                from     : UnsafeRawPointer(bitPattern: UInt(window.address))!,
                byteCount: Int(count * device.sectorSize)
            )
        }

        let accepted = device.submit(
            writing ? .write : .read,
            sector: sector,
            count : count,
            into  : free
        )

        guard accepted == .ok else {
            requests.cancel(free)
            return accepted
        }

        guard requests.submitted(free) else {
            requests.cancel(free)
            return .deviceRefused
        }

        return nil
    }


    /// Says once that the shared queue is full, and answers `queueFull`.
    ///
    /// Backpressure on a resource everybody shares, and it is answered by asking
    /// again: the four requests holding it are with the device and the device
    /// will answer them. Not the same thing as a client that has run out of its
    /// own names, which is answered by collecting.
    private mutating func saturated() -> BlockStatus {

        if saturations < UInt32.max { saturations += 1 }

        if saturations == 1 {
            print("[ DISK  ] all four slots are out, requests are being refused")
        }

        return .queueFull
    }


    /// Puts a flush in a slot of its own, so it is ordered by the device against
    /// everything already accepted and answered like any other request.
    private mutating func startFlush(_ request: ReceivedMessage) -> BlockStatus? {

        switch device.durability {
            // Nothing to empty, so the barrier is already true. Not a shortcut:
            // the completions are the order on such a device.
            case .onCompletion:
                return .ok

            // The device never negotiated a way to be asked, so a flush request
            // would be a command it did not agree to take and an `ok` here would
            // be this server inventing a guarantee on its behalf.
            case .unknown:
                return .durabilityUnknown

            case .onFlush:
                break
        }

        // A flush moves no bytes, so it needs no window - but its answer has to be
        // filed against an attachment, or it is an answer no session can collect.
        // Asked before the device is given anything, so a caller with no window
        // costs the disk nothing.
        guard let held = attachment(of: request.identity) else { return .notAttached }

        guard let free = device.freeSlot() else { return saturated() }

        guard requests.reserve(free, BlockRequests.Pending(
            client    : held.slot,
            identity  : request.identity,
            epoch     : held.attachment.epoch,
            tag       : nil,
            copiesBack: false
        )) else { return .queueFull }

        let accepted = device.submit(.flush, sector: 0, count: 0, into: free)

        guard accepted == .ok else {
            requests.cancel(free)
            return accepted
        }

        guard requests.submitted(free) else {
            requests.cancel(free)
            return .deviceRefused
        }

        return nil
    }


    /// Starts a transfer whose completion will be collected later.
    ///
    /// There is no direct reply: the client sent this rather than called it.
    /// Once an attachment and a valid tag have been established, every
    /// non-duplicate refusal is filed under that tag for `collect`.  That keeps
    /// backpressure observable without serialising admission, and a duplicate
    /// is left alone so it cannot overwrite the live request it duplicates.
    private mutating func begin(_ request: ReceivedMessage) {

        let named = BlockOperation.begun(request.message)

        // A well-formed BlockClient checks this before sending. A hostile
        // caller has no valid tag under which an answer could be collected, so
        // it receives no fake completion and cannot reach a cell out of bounds.
        guard BlockQueue.valid(named.slot) else { return }

        // The attachment first, because a refusal has to be recorded against one:
        // an answer filed under no attachment is an answer no session can collect,
        // which is the shape of a client waiting for ever. A client with no window
        // has nowhere for the bytes to go and nothing to collect them with, so
        // there is nothing to say to it and nothing said.
        guard let held = attachment(of: request.identity) else { return }

        let client = held.slot
        let window = held.attachment

        // Reads only. A write that overlapped other writes would put the order
        // they reach the medium in the device's hands, and that order is the
        // whole of why a power cut does not lose a file here.
        guard !named.write else {
            fileBeginRefusal(.readOnly, tag: named.slot, held: held)
            return
        }

        let count  = UInt64(request.message.words[0])
        let sector = BlockOperation.sector(of: request.message)

        let page = BlockQueue.offset(of: named.slot, pageSize: Self.pageSize)

        guard count > 0, count <= device.maximumRun,
              window.covers(page, count * device.sectorSize)
        else {
            fileBeginRefusal(.tooLong, tag: named.slot, held: held)
            return
        }

        // The name, before the doorbell and before a driver slot is taken. A
        // second request under it has nowhere for its answer to go.
        let admitted = requests.admits(client: client, tag: named.slot)
        guard admitted == .ok else {
            noteThrottle()
            // A duplicate tag is already owned by its first request. Do not
            // replace its completion with the duplicate's refusal.
            return
        }

        guard let free = device.freeSlot() else {
            fileBeginRefusal(saturated(), tag: named.slot, held: held)
            return
        }

        // Everything held before the device is told anything: the driver slot,
        // the owner, and the cell this answer will be filed in.
        guard requests.reserve(free, BlockRequests.Pending(
            client    : client,
            identity  : request.identity,
            epoch     : window.epoch,
            tag       : named.slot,
            copiesBack: true
        )) else {
            fileBeginRefusal(.queueFull, tag: named.slot, held: held)
            return
        }

        let accepted = device.submit(.read, sector: sector, count: count, into: free)

        guard accepted == .ok else {
            requests.cancel(free)
            fileBeginRefusal(accepted, tag: named.slot, held: held)
            return
        }

        guard requests.submitted(free) else {
            requests.cancel(free)
            fileBeginRefusal(.deviceRefused, tag: named.slot, held: held)
            return
        }
    }


    /// Files an access refusal for a one-way `begin`, when there is a genuine
    /// attachment/tag that can collect it.  A hostile untagged or unattached
    /// send has no result cell and cannot make the server fabricate one.
    private mutating func refuseBegin(_ request: ReceivedMessage, status: BlockStatus) {

        let named = BlockOperation.begun(request.message)

        guard BlockQueue.valid(named.slot),
              let held = attachment(of: request.identity)
        else { return }

        // This path runs before the regular begin admission.  A second denied
        // send can therefore name the first refusal (or a live request) and is
        // an ordinary duplicate, not evidence that bookkeeping was lost.
        fileBeginRefusal(status, tag: named.slot, held: held, duplicateIsBenign: true)
    }


    /// Files a rejection from a one-way begin, to be delivered by `collect`.
    private mutating func fileBeginRefusal(
        _ status: BlockStatus,
        tag: UInt32,
        held: (slot: Int, attachment: ShmAttachment),
        duplicateIsBenign: Bool = false
    ) {

        switch requests.fileRefusal(
            client  : held.slot,
            identity: held.attachment.identity,
            epoch   : held.attachment.epoch,
            tag     : tag,
            status  : status.rawValue
        ) {
            case .filed:
                return

            case .duplicate where duplicateIsBenign:
                noteThrottle()
                return

            case .duplicate, .invalid:
                // The ordinary begin path admitted this tag immediately before
                // it called here.  A refusal it cannot now file would lose the
                // one answer promised to a delivered begin, so stop rather
                // than misattribute an answer.  The generic authorization
                // path above explicitly handles its expected duplicate.
                wedged = true
        }
    }


    /// Says once that a client has run out of its own names.
    ///
    /// Its own, and that is the whole difference from `saturated`: nothing is
    /// taken from the device and nothing is taken from anybody else. The client
    /// has four answers waiting and the way out is to collect them.
    private mutating func noteThrottle() {

        guard requests.duplicateTags == 1 else { return }

        print("[ DISK  ] a client is out of names, its requests are being refused")
    }


    /// Hands over one finished transfer, or holds the call until there is one.
    private mutating func collect(_ request: ReceivedMessage) {

        guard let held = attachment(of: request.identity) else {
            _ = reply(message: BlockOperation.collected(.notAttached, slot: BlockQueue.none))
            return
        }

        let epoch = held.attachment.epoch

        // This attachment's answers and no others. A completion left over from
        // before this client attached again names a slot of a window that does
        // not exist, so handing it over would have a new session collect an
        // answer to a question it never asked.
        if let entry = requests.take(
            client: held.slot, identity: request.identity, epoch: epoch
        ) {
            _ = reply(message: BlockOperation.collected(
                BlockStatus(rawValue: entry.status) ?? .deviceRefused,
                slot: entry.tag
            ))
            return
        }

        // Nothing finished. Waiting is right only if something is on its way:
        // a client with nothing outstanding would otherwise be parked for ever
        // on an answer nobody is going to produce.
        guard requests.outstanding(
            client: held.slot, identity: request.identity, epoch: epoch
        ) else {
            _ = reply(message: BlockOperation.collected(.ok, slot: BlockQueue.none))
            return
        }

        collecting[held.slot] = true
    }


    /// Tells one client how a transfer of theirs ended.
    ///
    /// Answers a client already parked in `collect`, or files the answer for the
    /// `collect` still to come. A synchronous `read`/`write` - `tag` of nil - is
    /// parked inside its own call and answered there.
    ///
    /// The epoch is what makes the answer theirs. A client parked in `collect`
    /// under a new attachment is not owed a transfer started under the old one,
    /// and filing that answer would be filing it where the new session will find
    /// it.
    private mutating func answer(
        _ identity: UInt32,
          _ epoch : UInt64,
          _ tag   : UInt32?,
          _ status: BlockStatus
    ) {
        guard let tag else {
            _ = reply(message: BlockOperation.answer(status), to: identity)
            return
        }

        guard let held = attachment(of: identity),
              held.attachment.matches(identity: identity, epoch: epoch)
        else {
            // The attachment this was made against is gone, so there is nobody
            // to tell and no cell of theirs to write into.
            return
        }

        if collecting[held.slot] {
            collecting[held.slot] = false

            // The name is free again the moment its answer is handed over, which
            // is what lets a client keep four transfers going round for ever.
            requests.delivered(client: held.slot, tag: tag)

            _ = reply(message: BlockOperation.collected(status, slot: tag), to: identity)
            return
        }

        guard requests.file(
            client  : held.slot,
            identity: identity,
            epoch   : epoch,
            tag     : tag,
            status  : status.rawValue
        ) else {
            // Not a client that asked for too much - one cell per name makes
            // that impossible - so it is this server's own counting.
            wedged = true
            return
        }
    }


    /// Takes the disk out of service because this server has lost count.
    private mutating func stopForBookkeeping() {

        guard wedged else { return }
        wedged = false

        print("[ DISK  ] a completion had nowhere to be recorded, ", terminator: "")
        printDec(UInt64(requests.lateCompletions), terminator: "")
        print(" late so far")

        device.giveUp("this server lost count of what it owes")
        failEverybody()
    }


    /// The device has spoken. Answers everybody whose slot came back.
    ///
    /// A loop, because one interrupt may cover several completions: a device is
    /// free to finish two requests and signal once, and a driver that read one
    /// entry per interrupt would leave the other outstanding for ever.
    public mutating func handle(interrupt fired: KernelInterrupt) {

        guard device.acknowledge(lines: fired.lines) else {
            // Not a completion, or the device has given up. If it has, everybody
            // waiting has to be told rather than left parked on a disk that will
            // never answer - which is the debt a queue owes and one request in
            // flight did not, because there the caller was already inside the
            // failing call.
            if device.dead { failEverybody() }
            if wedged { stopForBookkeeping() }
            return
        }

        while let done = device.collect() {

            // `nil` for a slot nothing was expecting a completion on, which is
            // the late-completion guard. See `BlockRequests.finished`.
            guard let pending = requests.finished(done.slot) else { continue }

            // Bounded as well as looked up: an index into a fixed array that
            // arrived out of a table is what an unchecked subscript is made of.
            let window = pending.client >= 0 && pending.client < Self.capacity
                ? attachments[pending.client].current
                : nil

            // The one comparison this whole feature is for. The client may have
            // replaced its attachment, and identity alone says yes to that.
            let theirs = window?.matches(
                identity: pending.identity, epoch: pending.epoch
            ) == true

            if pending.copiesBack, done.status == .ok, theirs, let window {

                // Into this transfer's own page of the window, which is the slot
                // the client named. One page each is what keeps four reads from
                // writing over each other.
                let page  = pending.tag.map {
                    BlockQueue.offset(of: $0, pageSize: Self.pageSize)
                } ?? 0

                let bytes = UInt64(done.count) * device.sectorSize

                // Checked again here and not only at submission: the window is
                // the one mapped *now*, and `theirs` above says it is the same
                // one, so this is the bound of the region actually being written.
                if window.covers(page, bytes) {
                    UnsafeMutableRawPointer(bitPattern: UInt(window.address))!
                        .advanced(by: Int(page))
                        .copyMemory(
                            from     : UnsafeRawPointer(device.page(of: done.slot)),
                            byteCount: Int(bytes)
                        )
                }
            }

            // A request whose attachment is gone is not answered at all: there is
            // nobody left to answer. Its caller either replaced the attachment,
            // in which case it was already told, or died.
            guard theirs else { continue }

            answer(pending.identity, pending.epoch, pending.tag, done.status)
        }

        if device.dead { failEverybody() }
        if wedged { stopForBookkeeping() }
    }


    /// Tells everybody still waiting that their request is not coming back.
    private mutating func failEverybody() {

        let lost = device.abandonOutstanding()

        for slot in 0..<BlockRequests.slots {
            guard lost[slot] || device.dead else { continue }

            // Asked before it is taken, so a slot that was already idle is not
            // counted as a completion that arrived late.
            guard requests.owner(of: slot) != nil,
                  let pending = requests.finished(slot)
            else { continue }

            answer(pending.identity, pending.epoch, pending.tag, .deviceRefused)
        }
    }


    /// Adopts the page a client will move its sectors through.
    ///
    /// The order is the whole of it. The new region is mapped and owned *first*,
    /// so a client whose second attach fails still has its first; only then is
    /// the old attachment taken apart, and taking it apart means answering the
    /// requests that were made against it, throwing away the answers nobody
    /// collected, and giving the window and the capability back. The attachment
    /// number is minted before any of that, so the one irreversible step is last.
    ///
    /// Nothing is taken until all of it has succeeded, so every refusal simply
    /// returns and the receive loop gives the grant back.
    private mutating func attach(_ request: inout ReceivedMessage) {

        let badge = request.identity

        guard badge != 0 else { return }
        guard let granted = request.grantedCap else { return }

        // The size comes from the kernel, not from the message. A client saying
        // four pages while granting one used to leave this process writing a
        // reply into three pages it does not have, which is a page fault at a
        // moment the client picked. The word in the request is not read at all.
        let pages = shmPages(handle: granted)
        guard ShmAttachment.accepts(pages: pages, atMost: Self.maximumPages) else { return }

        guard let epoch = epochs.next() else { return }

        let existing = slot(for: badge)

        // Before refusing, ask which of the eight are still there. A client that
        // died holding a slot used to hold it for the rest of the boot.
        if existing == nil, freeSlot() == nil { sweepDeadClients() }

        guard let slot = existing ?? freeSlot() else { return }

        let address = shmMap(handle: granted)
        guard UnsafeMutableRawPointer(bitPattern: UInt(address)) != nil else { return }

        let extent = UInt64(pages) * Self.pageSize

        guard let owned = request.takeGrant() else {
            _ = munmap(addr: address, size: extent)
            return
        }

        // Answered before the swap, because a parked caller has to be told with
        // the attachment it asked against still being the one installed.
        let displaced = attachments[slot].current

        if let displaced {
            for driver in 0..<BlockRequests.slots {
                guard let pending = requests.owner(of: driver),
                      pending.identity == displaced.identity,
                      pending.epoch == displaced.epoch
                else { continue }

                // A parked `read`/`write` is waiting inside its own call and has
                // to be let go; a `begin` is not waiting anywhere, and its
                // answer would be filed under an attachment that no longer
                // exists, so it is simply dropped with the rest.
                if pending.tag == nil {
                    _ = reply(
                        message: BlockOperation.answer(.notAttached),
                        to     : pending.identity
                    )
                }
            }

            _ = requests.abandon(epoch: displaced.epoch, of: displaced.identity)
            requests.discard(client: slot, epoch: displaced.epoch)
        }

        collecting[slot] = false

        // One store, and the old attachment comes back out of it. See
        // `ShmAttachment.Slot.install`.
        let letGo = attachments[slot].install(ShmAttachment(
            identity: badge,
            epoch   : epoch,
            address : address,
            extent  : extent,
            grant   : owned
        ))

        // Afterwards, and only afterwards. The new window is mapped and
        // installed, so a client whose second attach fails still has its first.
        if let letGo {
            surrender(letGo)

            // Attaching again is starting again, and a process starting again is
            // not still holding what it held before.
            if holder == badge { holder = nil }
        }
    }


    /// Lets go of every slot whose client is no longer running.
    ///
    /// The volume is not touched, and that is the one thing this must not do. Who
    /// holds the disk is an authority, given up by the holder saying so, by the
    /// holder starting over, or by a warden reporting the death (`reclaim`). A
    /// window is not an authority, so it needs no warden to take it back.
    private mutating func sweepDeadClients() {
        for index in 0..<Self.capacity {
            guard let held = attachments[index].current,
                  !identityAlive(held.identity) else { continue }

            release(slot: index)
        }
    }


    private func slot(for badge: UInt32) -> Int? {
        for index in 0..<Self.capacity where attachments[index].held(by: badge) {
            return index
        }
        return nil
    }

    /// The table slot and the window `badge` holds, if it holds one.
    private func attachment(of badge: UInt32) -> (slot: Int, attachment: ShmAttachment)? {
        guard let slot = slot(for: badge),
              let held = attachments[slot].current else { return nil }

        return (slot, held)
    }

    private func freeSlot() -> Int? {
        for index in 0..<Self.capacity where attachments[index].current == nil {
            return index
        }
        return nil
    }


    /// Lets go of one client's slot entirely: its window, its capability, and
    /// every answer it was owed.
    private mutating func release(slot: Int) {

        guard let held = attachments[slot].take() else {
            collecting[slot] = false
            return
        }

        // Every epoch and not only the last. A client that attached three times
        // and then died has answers filed under all three, and one left behind is
        // one that becomes somebody else's refusal when this slot is reused.
        requests.discard(client: slot, epoch: nil)

        // `collecting` above all: left set, it belongs to whoever takes this slot
        // next, whose first completion would answer a call they never made.
        collecting[slot] = false

        surrender(held)
    }


    /// Gives a window and its capability back.
    ///
    /// Unmapped before the capability is dropped, and both are needed: dropping a
    /// capability does not take the window out of this address space, and the area
    /// holds a reference of its own, so an attachment released without this leaves
    /// the page mapped and the region alive for the rest of the boot. A client
    /// that attaches twice would leak one each time.
    private func surrender(_ attachment: ShmAttachment) {
        _ = munmap(addr: attachment.address, size: attachment.extent)
        _ = capDrop(attachment.grant)
    }
}
