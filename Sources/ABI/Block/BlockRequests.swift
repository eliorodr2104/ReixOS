//
//  BlockRequests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

/// Whose each of the block server's outstanding requests is, and whose each
/// finished one was.
///
/// Six parallel arrays used to hold this inside the server, and what none of
/// them held was *which attachment* a request belonged to. So a client that
/// attached again while a read was with the device had that read's bytes copied
/// into whatever page the new attachment had mapped, and an uncollected
/// completion from before survived to be handed to the new session as if it were
/// its own. Both are one field, and it is the epoch.
///
/// **Then the answers were a pool, and that was the second bug.** Four cells for
/// everybody meant one client that stopped collecting filled them, the next
/// completion had nowhere to be recorded, and the server's answer to that was to
/// reset the device and fail every request every other client had outstanding. A
/// client could take the disk away from the machine by not asking for its own
/// answers. So the cells are not a pool any more: there is one per client per
/// tag, a tag names its cell, and a second request under a tag that already has
/// an answer coming is refused before the device is told anything. A client
/// cannot be owed more than it has names for, and a completion can therefore
/// always be filed.
///
/// Nothing here maps, unmaps, copies or replies. It says who is owed what, and
/// the server does the owing - which is why the answers can be checked on a host
/// with no disk and no processes.
public struct BlockRequests {

    /// Requests out with the device at once, one per driver slot.
    public static let slots = BlockQueue.depth

    /// How many clients the server holds windows for.
    ///
    /// The answer table is this wide, so it is the same number as the server's
    /// attachment table and not a number of its own. `InlineArray`'s length has
    /// to be a literal, so the thirty-two in `cellState` is the real bound and
    /// `cells` is the name for it.
    public static let clients = 8

    /// How many names one client may have outstanding at once.
    ///
    /// The same as the queue depth, because a tag names one of the pages of the
    /// client's own window and the window is the queue's depth wide.
    public static let tags = BlockQueue.depth

    /// Cells in the answer table: one per client per tag.
    public static let cells = clients * tags

    /// How many requests one client may have going at once.
    ///
    /// Not a policy number that could have been another. A tag is how a client
    /// names a request it will collect later, there are `tags` of them, and a
    /// second request under a name that is already spoken for is refused - so a
    /// client cannot exceed this even when it is trying to, and every one of
    /// those requests has a cell of its own waiting for its answer.
    public static var perClient: Int { tags }


    /// What one request is doing.
    ///
    /// Four states, and `reserved` is the one that was missing. Everything a
    /// request needs - a driver slot, an owner, and somewhere for its answer to
    /// go - is taken while it is `reserved`, which is *before* the device is
    /// told anything. A submission that fails then puts all of it back, and a
    /// completion cannot arrive for a request whose owner has not been written
    /// down yet.
    public enum State: UInt8, Equatable {

        /// Nothing here.
        case idle

        /// Accepted: its driver slot, its owner and its answer's place are held,
        /// and the device has not been rung for.
        case reserved

        /// Programmed into the queue and rung for.
        case inflight

        /// Finished, waiting for a `collect`.
        case done
    }


    /// One request out with the device.
    public struct Pending: Equatable {

        /// The attachment table slot the client held when it asked.
        public let client: Int

        public let identity: UInt32

        /// Which attachment of that client. What makes this request theirs and
        /// not their next session's.
        public let epoch: UInt64

        /// The name the client will collect this under, or nil for a plain
        /// `read`/`write` call whose caller is parked waiting for the answer.
        public let tag: UInt32?

        /// Whether the bytes travel back out of the driver's page into the
        /// client's window. A read does; a write has already had its bytes
        /// copied in, and a flush has none.
        public let copiesBack: Bool

        public init(
            client    : Int,
            identity  : UInt32,
            epoch     : UInt64,
            tag       : UInt32?,
            copiesBack: Bool
        ) {
            self.client     = client
            self.identity   = identity
            self.epoch      = epoch
            self.tag        = tag
            self.copiesBack = copiesBack
        }
    }


    /// One completion waiting to be collected.
    public struct Result: Equatable {
        public let tag   : UInt32
        public let status: UInt32

        public init(tag: UInt32, status: UInt32) {
            self.tag    = tag
            self.status = status
        }
    }


    /// What happened when a one-way `begin` needed an answer before it could
    /// reach the device.
    ///
    /// A duplicate is an expected admission result: its existing cell belongs
    /// to the earlier request or refusal and must stay untouched.  `invalid`
    /// is different - no bounded cell exists at all, so a server cannot safely
    /// promise a result to `collect`.
    public enum Refusal: Equatable {
        case filed
        case duplicate
        case invalid
    }


    // One entry per driver slot. Parallel arrays rather than an array of
    // `Pending?`, so nothing here allocates or copies an optional.
    private var slotState = InlineArray<4, State>(repeating: .idle)
    private var slotClient = InlineArray<4, Int>(repeating: 0)
    private var slotWho   = InlineArray<4, UInt32>(repeating: 0)
    private var slotEpoch = InlineArray<4, UInt64>(repeating: 0)
    private var slotTag   = InlineArray<4, UInt32?>(repeating: nil)
    private var slotBack  = InlineArray<4, Bool>(repeating: false)

    // One cell per client per tag: `client * tags + tag`.
    private var cellState  = InlineArray<32, State>(repeating: .idle)
    private var cellWho    = InlineArray<32, UInt32>(repeating: 0)
    private var cellEpoch  = InlineArray<32, UInt64>(repeating: 0)
    private var cellStatus = InlineArray<32, UInt32>(repeating: 0)

    /// Completions that arrived for a driver slot nothing was expecting one on.
    ///
    /// A slot that was cancelled, or already finished, or never handed to the
    /// device. The state on the slot is what says so, and this is the count: it
    /// must stay at zero on a device that answers what it was asked, and a
    /// number here is a late completion that was thrown away rather than
    /// attributed to whoever holds that slot now.
    public private(set) var lateCompletions: UInt32 = 0

    /// The most names one client ever had spoken for at once.
    ///
    /// The depth that is a property of the code rather than of the machine. A
    /// name is taken when a request is accepted and given back when its client
    /// collects the answer, so this rises when a client asks for a second thing
    /// before taking delivery of the first - which is what pipelining *is*.
    ///
    /// The driver has a high-water mark too, and it measures something else: how
    /// many requests were out *with the device* at once. That one is a race. A
    /// device fast enough to finish the first read before the second submission
    /// reaches it never has two out, however hard the client pipelines, and on
    /// this machine it sometimes is. It stays a diagnostic; this is the number
    /// worth asserting.
    public private(set) var deepestHeld = 0

    /// Requests refused because their name was already spoken for.
    ///
    /// The local throttle, counted. A client that never collects reaches four and
    /// stops; every request after that is refused here, before the device is told
    /// anything, and no other client notices.
    public private(set) var duplicateTags: UInt32 = 0

    public init() {}


    // MARK: - Cells

    /// Which cell a client's tag names, or nil when it names none.
    private static func cell(_ client: Int, _ tag: UInt32) -> Int? {
        guard client >= 0, client < clients, tag < UInt32(tags) else { return nil }

        return client * tags + Int(tag)
    }


    /// Whether `client` may start a request called `tag`, and the refusal when
    /// it may not.
    ///
    /// A request with no tag is a parked call: its caller is waiting inside it
    /// and its answer is a reply, so it needs no cell and cannot collide.
    ///
    /// Mutating, because the refusals are counted here. This is the door a server
    /// asks at before it takes a driver slot or rings a doorbell, and the count
    /// is the local throttle's only report.
    public mutating func admits(client: Int, tag: UInt32?) -> BlockStatus {

        let answer = room(client: client, tag: tag)

        // Saturating, like every other report here: one that wrapped would say
        // no client had ever been refused.
        if answer == .duplicateTag, duplicateTags < UInt32.max { duplicateTags += 1 }

        return answer
    }


    /// The same question, without counting the answer.
    ///
    /// For `reserve`, which a server reaches only after `admits` has said yes: a
    /// refusal there is the same refusal counted twice.
    private func room(client: Int, tag: UInt32?) -> BlockStatus {

        guard client >= 0, client < Self.clients else { return .notAttached }
        guard let tag else { return .ok }

        guard let cell = Self.cell(client, tag) else { return .tooLong }

        return cellState[cell] == .idle ? .ok : .duplicateTag
    }


    // MARK: - Out with the device

    /// Holds everything a request needs before the device is told anything.
    ///
    /// The driver slot, who the request belongs to, and - for a named one - the
    /// cell its answer will be filed in. `false` when any of the three cannot be
    /// held, and in that case none of them is: a caller that is refused here has
    /// taken nothing.
    public mutating func reserve(_ slot: Int, _ pending: Pending) -> Bool {

        guard slot >= 0, slot < Self.slots, slotState[slot] == .idle else { return false }

        guard room(client: pending.client, tag: pending.tag) == .ok else { return false }

        if let tag = pending.tag, let cell = Self.cell(pending.client, tag) {
            cellState[cell]  = .reserved
            cellWho[cell]    = pending.identity
            cellEpoch[cell]  = pending.epoch
            cellStatus[cell] = 0
        }

        let held = held(by: pending.client)
        if held > deepestHeld { deepestHeld = held }

        slotState[slot]  = .reserved
        slotClient[slot] = pending.client
        slotWho[slot]    = pending.identity
        slotEpoch[slot]  = pending.epoch
        slotTag[slot]    = pending.tag
        slotBack[slot]   = pending.copiesBack

        return true
    }


    /// Puts back everything `reserve` took, for a submission that never reached
    /// the device.
    ///
    /// Both halves, which is the point of there being one call: a cancel that
    /// freed the driver slot and left the cell held would cost the client that
    /// name for the rest of the boot.
    public mutating func cancel(_ slot: Int) {

        guard slot >= 0, slot < Self.slots, slotState[slot] == .reserved else { return }

        if let tag = slotTag[slot], let cell = Self.cell(slotClient[slot], tag),
           cellState[cell] == .reserved {
            cellState[cell] = .idle
        }

        forget(slot)
    }


    /// The device has been told. `false` when the slot was not reserved, which is
    /// a caller that submitted without reserving first.
    public mutating func submitted(_ slot: Int) -> Bool {

        guard slot >= 0, slot < Self.slots, slotState[slot] == .reserved else { return false }

        slotState[slot] = .inflight

        if let tag = slotTag[slot], let cell = Self.cell(slotClient[slot], tag) {
            cellState[cell] = .inflight
        }

        return true
    }


    /// Who a slot that is out with the device belongs to.
    public func owner(of slot: Int) -> Pending? {

        guard slot >= 0, slot < Self.slots, slotState[slot] == .inflight else { return nil }

        return Pending(
            client    : slotClient[slot],
            identity  : slotWho[slot],
            epoch     : slotEpoch[slot],
            tag       : slotTag[slot],
            copiesBack: slotBack[slot]
        )
    }


    /// Takes a completed request out of the driver-slot table.
    ///
    /// `nil` for a slot nothing was expecting a completion on, which is the
    /// late-completion guard: a slot that was cancelled, or has already been
    /// finished, or was never handed over, has no owner to attribute this to -
    /// and the owner it *would* be attributed to is whoever holds the slot now.
    public mutating func finished(_ slot: Int) -> Pending? {

        guard let pending = owner(of: slot) else {
            if slot >= 0, slot < Self.slots, lateCompletions < UInt32.max {
                lateCompletions += 1
            }
            return nil
        }

        forget(slot)
        return pending
    }


    /// Every request of one attachment, taken out of the driver-slot table.
    ///
    /// They stay out with the device - a request already programmed into a
    /// virtqueue cannot be recalled - so the completion will arrive and find
    /// nothing waiting, which is exactly what has to happen: the window it would
    /// have been copied into is not that request's window any more.
    public mutating func abandon(epoch: UInt64, of identity: UInt32) -> InlineArray<4, Bool> {

        var taken = InlineArray<4, Bool>(repeating: false)

        for slot in 0..<Self.slots
        where slotState[slot] != .idle && slotWho[slot] == identity && slotEpoch[slot] == epoch {
            taken[slot] = true
            forget(slot)
        }

        return taken
    }


    /// Every request there is, taken out of the table. For a device that has
    /// stopped answering.
    public mutating func abandonAll() -> InlineArray<4, Bool> {

        var taken = InlineArray<4, Bool>(repeating: false)

        for slot in 0..<Self.slots where slotState[slot] != .idle {
            taken[slot] = true
            forget(slot)
        }

        return taken
    }


    /// Frees a driver slot without touching the cell that goes with it.
    private mutating func forget(_ slot: Int) {
        slotState[slot] = .idle
        slotTag[slot]   = nil
    }


    // MARK: - Finished and not yet collected

    /// Files an answer under a client's own name for it.
    ///
    /// It cannot fail for a name that has no answer waiting, and that is the
    /// whole point of the cell table: a tag names its cell, so the place an
    /// answer goes was held when the request was accepted. The one refusal is a
    /// name that already has an answer nobody has collected, which `admits`
    /// refuses a second request under in the first place.
    public mutating func file(
        client  : Int,
        identity: UInt32,
        epoch   : UInt64,
        tag     : UInt32,
        status  : UInt32
    ) -> Bool {

        guard let cell = Self.cell(client, tag) else { return false }

        switch cellState[cell] {
            // Refused before it was ever started, so nothing was held for it.
            case .idle:
                break

            case .reserved, .inflight:
                guard cellWho[cell] == identity, cellEpoch[cell] == epoch else {
                    return false
                }

            // There is already an answer here that nobody has taken.
            case .done:
                return false
        }

        cellState[cell]  = .done
        cellWho[cell]    = identity
        cellEpoch[cell]  = epoch
        cellStatus[cell] = status

        return true
    }


    /// Records an admission refusal for a one-way `begin`.
    ///
    /// A `begin` is sent rather than called, so it has no immediate reply.  A
    /// refusal therefore has to occupy the caller's tag until `collect` takes
    /// it.  Only an idle tag may become such a result: a duplicate must never
    /// turn the live request already named by that tag into a refusal.
    ///
    /// This is deliberately narrower than `file`, which is also the path for a
    /// genuine device completion and therefore accepts a reserved or inflight
    /// tag.  Admission happens before either of those states exists.
    public mutating func fileRefusal(
        client  : Int,
        identity: UInt32,
        epoch   : UInt64,
        tag     : UInt32,
        status  : UInt32
    ) -> Refusal {

        guard let cell = Self.cell(client, tag) else { return .invalid }

        guard cellState[cell] == .idle else {
            if duplicateTags < UInt32.max { duplicateTags += 1 }
            return .duplicate
        }

        cellState[cell]  = .done
        cellWho[cell]    = identity
        cellEpoch[cell]  = epoch
        cellStatus[cell] = status

        return .filed
    }


    /// Compatibility boolean for callers that only need to know whether a
    /// refusal was stored.  One-way server policy uses `fileRefusal` so it can
    /// distinguish a benign duplicate from an impossible cell.
    public mutating func reject(
        client  : Int,
        identity: UInt32,
        epoch   : UInt64,
        tag     : UInt32,
        status  : UInt32
    ) -> Bool {

        fileRefusal(
            client: client, identity: identity, epoch: epoch, tag: tag, status: status
        ) == .filed
    }


    /// Lets go of a cell whose answer went straight to a caller parked in
    /// `collect`, so the name is free again.
    public mutating func delivered(client: Int, tag: UInt32) {
        guard let cell = Self.cell(client, tag) else { return }

        cellState[cell] = .idle
    }


    /// The oldest answer waiting for this attachment, taken out.
    ///
    /// The epoch is what makes it *this* attachment's. A completion left over
    /// from before a client attached again is not that client's news any more: it
    /// names a page of a window that no longer exists, and handing it over would
    /// have the new session collect an answer to a question it never asked.
    public mutating func take(
        client  : Int,
        identity: UInt32,
        epoch   : UInt64
    ) -> Result? {

        guard client >= 0, client < Self.clients else { return nil }

        for tag in 0..<Self.tags {
            let cell = client * Self.tags + tag

            guard cellState[cell] == .done,
                  cellWho[cell] == identity,
                  cellEpoch[cell] == epoch
            else { continue }

            cellState[cell] = .idle
            return Result(tag: UInt32(tag), status: cellStatus[cell])
        }

        return nil
    }


    /// Throws away everything belonging to attachments that are gone.
    ///
    /// Called with the epoch being replaced, and with `nil` for every epoch of a
    /// client whose slot is being let go. Not doing it is how a stale answer
    /// reaches a new session, or somebody else's session when the slot is reused.
    public mutating func discard(client: Int, epoch: UInt64?) {

        guard client >= 0, client < Self.clients else { return }

        for tag in 0..<Self.tags {
            let cell = client * Self.tags + tag
            guard cellState[cell] != .idle else { continue }

            guard let epoch else {
                cellState[cell] = .idle
                continue
            }

            if cellEpoch[cell] == epoch { cellState[cell] = .idle }
        }
    }


    /// Whether this attachment has anything with the device or waiting to be
    /// collected.
    ///
    /// What tells a `collect` worth holding from one that would wait for ever.
    /// Only named requests count: a parked `read` has its own caller waiting
    /// inside it and is answered there.
    public func outstanding(
        client  : Int,
        identity: UInt32,
        epoch   : UInt64
    ) -> Bool {

        guard client >= 0, client < Self.clients else { return false }

        for tag in 0..<Self.tags {
            let cell = client * Self.tags + tag

            if cellState[cell] != .idle,
               cellWho[cell] == identity,
               cellEpoch[cell] == epoch { return true }
        }

        return false
    }


    /// How many of `client`'s names are spoken for. For the throttle's own
    /// report, and for the tests.
    public func held(by client: Int) -> Int {

        guard client >= 0, client < Self.clients else { return 0 }

        var many = 0
        for tag in 0..<Self.tags where cellState[client * Self.tags + tag] != .idle {
            many += 1
        }

        return many
    }


    /// What one request is doing, by the name its client gave it.
    public func state(client: Int, tag: UInt32) -> State {
        guard let cell = Self.cell(client, tag) else { return .idle }

        return cellState[cell]
    }


    /// What one driver slot is doing.
    public func state(slot: Int) -> State {
        guard slot >= 0, slot < Self.slots else { return .idle }

        return slotState[slot]
    }


    /// How many answers are waiting to be collected, by anybody. For the tests.
    public var waiting: Int {
        var many = 0
        for cell in 0..<Self.cells where cellState[cell] == .done { many += 1 }

        return many
    }
}
