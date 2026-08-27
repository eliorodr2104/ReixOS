//
//  FileSystemContainers.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// Containers: where a boundary on the disk comes from, and what it costs.
///
/// A container is a folder with two more facts about it: how much room it may
/// use, and which container it sits in. Everything else follows from those two.
/// There is no separate file system per container, no mount table and no
/// prefix matching on paths. One tree, and a place in it.
///
/// The boundary is not enforced here. It is *decided* here, by `contains`, and
/// enforced by the server one layer up, which refuses to act on anything the
/// caller's own container does not contain. What this file provides is the
/// answer to "is that thing inside this place", and the arithmetic of a room
/// that was given rather than found.
extension FileSystem {

    public struct TextResult {
        public let status: FSStatus
        public let length: Int

        init(_ status: FSStatus, _ length: Int = 0) {
            self.status = status
            self.length = length
        }
    }

    public struct RoomResult {
        public let status: FSStatus
        public let value : (quota: UInt32, used: UInt32, left: UInt32)?

        init(
            _ status: FSStatus,
            _ value: (quota: UInt32, used: UInt32, left: UInt32)? = nil
        ) {
            self.status = status
            self.value  = value
        }
    }

    /// How deep the containers may nest before a walk is treated as a loop.
    ///
    /// A corrupt disk can point a container at its own descendant, and a walk
    /// up such a chain never ends. A depth limit turns that into a refusal.
    static var nestingLimit: Int { 32 }


    mutating func admitContainer() -> FSStatus {
        if let count = containerCount {
            return count < Self.maxContainersV02 ? .ok : .unsupportedCapacity
        }

        var count = 0

        for index in 0..<plan.objectCount {
            switch readObject(index) {
                case .live(let record):
                    guard record.kind == .container else { continue }
                    guard count < Self.maxContainersV02 else {
                        containerCount = nil
                        return .unsupportedCapacity
                    }
                    count += 1
                    guard count < Self.maxContainersV02 else {
                        containerCount = count
                        return .unsupportedCapacity
                    }

                case .free:
                    continue

                case .outside:
                    return .deviceFailed

                case .failed(let why):
                    return why

                case .corrupt:
                    return .quarantined
            }
        }

        containerCount = count
        return .ok
    }


    /// The container an object's blocks are charged to.
    ///
    /// A container is charged to itself, which is what makes `charged` usable
    /// as "the place this thing is" without the caller having to ask what kind
    /// of thing it is first.
    ///
    /// The container named has to be one. A record pointing at a file as its
    /// container is a quota that cannot add up, and every caller here then reads
    /// and writes `quota` and `used` on a file's record: `charge` compared the
    /// room left of something that has none, and `refund` wrote a number back
    /// into it. No disk this build wrote has one, so it is held rather than
    /// worked around.
    public mutating func charged(_ index: UInt32) -> UInt32? {
        guard let record = object(index), record.standing == .live else { return nil }

        guard record.kind != .container else { return index }

        guard let owner = object(record.container) else { return nil }

        guard owner.standing == .live, owner.kind == .container else {
            quarantine()
            return nil
        }

        return record.container
    }


    /// How many parent links there are between `index` and the machine's root.
    ///
    /// Zero for the root itself. `nil` when the chain does not reach the root
    /// inside `nestingLimit` steps, and on a disk this build wrote that can only
    /// be a loop: the depth is enforced where it grows, so no tree gets that
    /// deep. So the volume is held there rather than the walk simply giving up.
    ///
    /// The one-step loop - an object that is its own parent - is caught earlier
    /// and more cheaply, by `object` itself.
    mutating func depth(of index: UInt32) -> Int? {

        var here  = index
        var steps = 0

        while here != FSLayout.rootObject {
            guard steps < Self.nestingLimit else {
                quarantine()
                return nil
            }

            guard let record = object(here), record.standing == .live else { return nil }

            here   = record.parent
            steps += 1
        }

        return steps
    }


    /// Whether `index` is inside `root`, or is `root` itself.
    ///
    /// This is the containment check, and it is a walk up the *parent* chain
    /// rather than a comparison of paths. A process that guesses an object
    /// number belonging to somewhere else fails here, because the number tells
    /// the truth about where it lives and guessing cannot change that.
    ///
    /// Parents and not containers, so that `root` may be a folder or even a
    /// single file and not only a whole container. That is what makes a
    /// subtree something one process can hand to another.
    public mutating func contains(
        _      index: UInt32,
        within root : UInt32
    ) -> Bool {

        guard let start = object(index),
                  start.standing == .live else { return false }
        
        guard index != root else { return true }

        var here  = start.parent
        var depth = 0

        while depth < Self.nestingLimit {
            if here == root { return true }

            guard let record = object(here), record.standing == .live else { return false }

            // The machine's own root is its own parent, and that is where every
            // walk ends. The depth limit would end it anyway; this is speed.
            if record.parent == here { return false }

            here   = record.parent
            depth += 1
        }

        // Off the end of the walk. See `depth(of:)`.
        quarantine()
        return false
    }


    /// Makes a container inside `folder`, out of `folder`'s own room.
    ///
    /// The room comes from the container the new one is going into, not from
    /// the disk. That is the whole of the quota model in one line: a container
    /// cannot give away what it has not got, and giving reduces what it has.
    public mutating func createContainer(
        _  name  : UnsafeRawPointer,
           length: Int,
           quota : UInt32,
        in folder: UInt32
    ) -> (status: FSStatus, object: UInt32) {

        // The parent's room and the child's, plus the record and the name, in one
        // transaction: a container half made is room charged to a parent that
        // nothing holds.
        let admitted = admitContainer()
        guard admitted == .ok else { return (admitted, 0) }

        let begun = begin()
        guard begun == .ok else { return (begun, 0) }

        let made  = createContainerStaged(name, length: length, quota: quota, in: folder)
        let ended = finish(made.status)

        guard ended == .ok else {
            if made.status == .ok { containerCount = nil }
            return (ended, 0)
        }

        if let count = containerCount { containerCount = count + 1 }
        return (ended, made.object)
    }


    mutating func createContainerStaged(
        _  name  : UnsafeRawPointer,
           length: Int,
           quota : UInt32,
        in folder: UInt32
    ) -> (status: FSStatus, object: UInt32) {

        guard let parent = charged(folder) else { return (.notFound, 0) }
       
        guard let owner = object(parent),
                  owner.standing == .live,
                  owner.kind == .container else {
            return (.wrongKind, 0)
        }

        guard owner.roomLeft >= quota else { return (.noSpace, 0) }

        // The staged body and not the public door: that one opens a transaction of
        // its own, and this is already inside one. There are no nested
        // transactions and there is no need for any - the whole of this is one
        // act.
        let made = createStaged(name, length: length, kind: .container, in: folder)
        guard made.status == .ok else { return (made.status, 0) }

        // Re-read: `create` may have grown the folder, which charges the parent
        // and would make a copy taken before it stale.
        guard var refreshed = object(parent) else { return (.notFound, 0) }

        // No unmaking by hand. Abandoning the transaction is what unmakes it, and
        // it unmakes the folder's growth with it.
        guard refreshed.roomLeft >= quota else { return (.noSpace, 0) }

        // Checked, though the guard above bounds it: the number on the left came
        // off a disk, and the subtraction that finds out otherwise traps.
        let (kept, under) = refreshed.quota.subtractingReportingOverflow(quota)
        guard !under else { return (.noSpace, 0) }

        refreshed.quota = kept

        let booked = store(refreshed, at: parent)
        guard booked == .ok else { return (booked, 0) }

        guard var fresh = object(made.object) else { return (explain(.notFound), 0) }
        fresh.quota     = quota
        fresh.container = parent

        let written = store(fresh, at: made.object)
        guard written == .ok else { return (written, 0) }

        return (.ok, made.object)
    }


    /// Moves room from a container to one directly inside it.
    ///
    /// Only downward, and only one step. A container hands room to something it
    /// contains, which is the same shape as handing it authority, and neither
    /// travels sideways.
    public mutating func grantQuota(
        _    blocks: UInt32,
        from parent: UInt32,
        to   child : UInt32
    ) -> FSStatus {

        // Both records in one transaction: room that has left the parent and not
        // arrived at the child is room nothing on the disk holds.
        let begun = begin()
        guard begun == .ok else { return begun }

        return finish(grantQuotaStaged(blocks, from: parent, to: child))
    }


    mutating func grantQuotaStaged(
        _    blocks: UInt32,
        from parent: UInt32,
        to   child : UInt32
    ) -> FSStatus {

        guard var giver = object(parent),
                  giver.standing == .live,
                  giver.kind == .container else { return .wrongKind }

        guard var taker = object(child),
                  taker.standing == .live,
                  taker.kind == .container else { return .wrongKind }
        
        guard taker.container == parent else { return .notFound }

        guard giver.roomLeft >= blocks else { return .noSpace }

        let (given, over) = taker.quota.addingReportingOverflow(blocks)
        guard !over else { return .noSpace }

        // Checked both ways. `roomLeft >= blocks` bounds this one, and the bound
        // was read off a disk, which is exactly when a trap is not the answer.
        let (left, under) = giver.quota.subtractingReportingOverflow(blocks)
        guard !under else { return .noSpace }

        giver.quota = left
        taker.quota = given

        let taken = store(giver, at: parent)
        guard taken == .ok else { return taken }

        return store(taker, at: child)
    }


    /// What an object is called, written into `destination`.
    ///
    /// Nothing on this disk has a name of its own: the name is the entry in the
    /// folder that points at it, which is why this is a scan and not a field.
    /// The machine's root is the exception, because nothing points at it, and
    /// it carries its name in the superblock instead.
    public mutating func nameResult(
        of   container  : UInt32,
        into destination: UnsafeMutableRawPointer,
        capacity: Int
    ) -> TextResult {

        func clear() {
            guard capacity > 0 else { return }
            destination.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        }

        guard container != FSLayout.rootObject else {
            var name = InlineArray<16, UInt8>(repeating: 0)
            let length = withUnsafeMutableBytes(of: &name) { bytes in
                machineName(into: bytes.baseAddress!)
            }

            guard length > 0 else { return TextResult(.notFound) }

            guard capacity >= length else {
                clear()
                return TextResult(.bufferTooSmall)
            }

            let out = destination.assumingMemoryBound(to: UInt8.self)
            for index in 0..<length { out[index] = name[index] }
            return TextResult(.ok, length)
        }

        let record: FSObject
        switch readObject(container) {
            case .live(let live): record = live
            case .free, .outside: return TextResult(.notFound)
            case .failed(let why): return TextResult(why)
            case .corrupt: return TextResult(.quarantined)
        }

        var found: FSEntry? = nil

        let walked = forEachEntry(in: record.parent) { entry, _, _ in
            guard found == nil, entry.object == container else { return }
            found = entry
        }

        guard walked == .ok else { return TextResult(walked) }
        guard let found else { return TextResult(.notFound) }

        let length = Int(found.length)
        guard capacity >= length else {
            clear()
            return TextResult(.bufferTooSmall)
        }

        let out = destination.assumingMemoryBound(to: UInt8.self)
        for index in 0..<length { out[index] = found.name[index] }

        return TextResult(.ok, length)
    }


    public mutating func name(
        of   container  : UInt32,
        into destination: UnsafeMutableRawPointer
    ) -> Int {
        nameResult(
            of: container, into: destination, capacity: FSLayout.nameLimit
        ).length
    }

    /// Gives an object a new name, a new folder, or both.
    ///
    /// Within one container only. Moving something into another container would
    /// have to move its blocks off one quota and onto another, and doing that
    /// halfway is worse than refusing: whoever wants that can copy and delete,
    /// which is two operations that each finish.
    ///
    /// A folder cannot be moved inside itself. That is not a nicety - a cycle
    /// in the parent chain is a tree that no longer ends, and every walk in
    /// this file system is a walk up that chain.
    ///
    /// **Depth is two rules, because only the first is cheap to be sure of.**
    /// Whatever moves must land inside the walk; and something with a subtree may
    /// not land *deeper* than it was. Measuring how tall that subtree is would be
    /// a walk of the whole of it, and without the measurement a move that looks
    /// legal here can push a descendant off the end of every later walk.
    ///
    /// A file has no subtree and neither has an empty folder, so both may go
    /// anywhere the first rule allows. A non-empty folder moving deeper is
    /// refused the same way, and for the same reason, as a move between two
    /// containers: copy and delete are two operations that each finish.
    public mutating func relocate(
        _      name     : UnsafeRawPointer,
               length   : Int,
        from   folder   : UInt32,
        to     target   :  UInt32,
        as     newName  : UnsafeRawPointer,
        length newLength: Int
    ) -> FSStatus {

        // The old folder, the new folder and the record that says where the thing
        // lives, in one transaction. This was the operation with the most
        // carefully argued write order in the whole format, and every one of the
        // outcomes that order was chosen to survive - a stray name here, a
        // duplicate name there - is now not an outcome at all.
        let begun = begin()
        guard begun == .ok else { return begun }

        return finish(relocateStaged(
            name, length: length, from: folder,
            to: target, as: newName, length: newLength
        ))
    }


    mutating func relocateStaged(
        _      name     : UnsafeRawPointer,
               length   : Int,
        from   folder   : UInt32,
        to     target   :  UInt32,
        as     newName  : UnsafeRawPointer,
        length newLength: Int
    ) -> FSStatus {

        let found = lookup(name, length: length, in: folder)
        guard case .at(let object) = found else { return found.refusal }

        guard object != FSLayout.rootObject else { return .wrongKind }

        guard let destination = self.object(target) else { return explain(.notFound) }
        guard destination.standing == .live, destination.kind != .file else {
            return .wrongKind
        }

        guard let home = charged(folder), let into = charged(target), home == into else {
            return explain(.wrongKind)
        }

        // Into itself, or into something inside itself.
        guard target != object, !contains(target, within: object) else { return .wrongKind }

        // Two rules, and the doc above says why there are two.
        guard let landing = depth(of: target) else { return explain(.notFound) }
        guard landing + 1 < Self.nestingLimit else { return .tooDeep }

        guard let leaving = depth(of: folder) else { return explain(.notFound) }

        if landing > leaving, let moving = self.object(object), moving.kind != .file {
            let empty = emptiness(of: object)
            guard empty == .ok else {
                return empty == .notEmpty ? .tooDeep : empty
            }
        }

        // Nothing to do, and doing it anyway would unlink and relink the same
        // entry, which is a window where it exists nowhere.
        if folder == target, FSEntry(object: object, name: newName, length: newLength)?
            .matches(name, length: length) == true {
            return .ok
        }

        // Only `notFound` is permission to write the new name.
        let taken = lookup(newName, length: newLength, in: target)
        guard taken.refusal == .notFound else {
            return taken.refusal == .ok ? .exists : taken.refusal
        }

        guard let entry = FSEntry(object: object, name: newName, length: newLength) else {
            return .badName
        }

        // Three writes and no order to argue about. Every stopping point this
        // sequence used to be arranged around - reachable by two names, reachable
        // by one it does not claim - is a stopping point the transaction does not
        // have: either all three land or none of them does.
        let linked = link(entry, in: target)
        guard linked == .ok else { return linked }

        guard var record = self.object(object) else { return explain(.notFound) }
        record.parent   = target
        record.modified = now

        let moved = store(record, at: object)
        guard moved == .ok else { return moved }

        return unlink(name, length: length, from: folder)
    }


    /// Renames the machine itself.
    public mutating func setMachineName(
        _ text  : UnsafeRawPointer,
          length: Int
    ) -> FSStatus {

        guard length > 0, length <= FSLayout.machineNameLimit else { return .badName }

        let bytes = text.assumingMemoryBound(to: UInt8.self)

        for index in 0..<length {
            let byte = bytes[index]
            
            guard byte > 0x20, byte < 0x7F,
                  byte != UInt8(ascii: "/"), byte != UInt8(ascii: ":")
            else { return .badName }
        }

        // Through the dual-copy protocol like every other superblock change, and
        // not through the journal: the journal's targets are the disk's
        // bookkeeping blocks, and the superblock is where the layout lives.
        return rename(machine: text, length: length)
    }


    /// Writes the path from `root` down to `object`, in the syntax it would be
    /// typed in, and answers how long it is.
    ///
    /// Which separator goes before a name is decided by what the name refers
    /// to: a container is reached with `::` and everything else with `/`. So
    /// the written path says, at a glance, where the boundaries are - which is
    /// the reason the two separators are different in the first place.
    ///
    /// Zero when `object` is not inside `root`. There is no path to somewhere
    /// you cannot reach, and inventing one would be the only way this could
    /// leak a name from above.
    public mutating func pathResult(
        of     object     : UInt32,
        within root       : UInt32,
        into   destination: UnsafeMutableRawPointer,
               capacity   : Int
    ) -> TextResult {

        func clear() {
            guard capacity > 0 else { return }
            destination.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        }

        var chain = InlineArray<32, UInt32>(repeating: 0)
        var depth = 0
        var here  = object

        // Up to the root, remembering the way. The root itself is not in the
        // chain: its name is written first and everything else hangs off it.
        while here != root {
            guard depth < chain.count else {
                quarantine()
                clear()
                return TextResult(.quarantined)
            }

            let record: FSObject
            switch readObject(here) {
                case .live(let live): record = live
                case .free, .outside:
                    clear()
                    return TextResult(.notFound)
                case .failed(let why):
                    clear()
                    return TextResult(why)
                case .corrupt:
                    clear()
                    return TextResult(.quarantined)
            }

            guard record.parent != here else {
                quarantine()
                clear()
                return TextResult(.quarantined)
            }

            chain[depth] = here
            depth += 1
            here   = record.parent
        }

        var staged = InlineArray<2048, UInt8>(repeating: 0)
        var written = 0
        var part = InlineArray<56, UInt8>(repeating: 0)

        func append(_ byte: UInt8) -> Bool {
            guard written < staged.count else { return false }
            staged[written] = byte
            written += 1
            return true
        }

        func appendName(_ object: UInt32) -> FSStatus {
            let result = withUnsafeMutableBytes(of: &part) { bytes in
                nameResult(of: object, into: bytes.baseAddress!, capacity: bytes.count)
            }
            guard result.status == .ok else { return result.status }
            guard written + result.length <= staged.count else { return .bufferTooSmall }
            for index in 0..<result.length {
                staged[written] = part[index]
                written += 1
            }
            return .ok
        }

        let rootName = appendName(root)
        guard rootName == .ok else {
            clear()
            return TextResult(rootName)
        }

        var step = depth
        while step > 0 {
            step -= 1

            let node = chain[step]
            let record: FSObject
            switch readObject(node) {
                case .live(let live): record = live
                case .free, .outside:
                    clear()
                    return TextResult(.notFound)
                case .failed(let why):
                    clear()
                    return TextResult(why)
                case .corrupt:
                    clear()
                    return TextResult(.quarantined)
            }

            let mark: (UInt8, Int) = record.kind == .container
                ? (UInt8(ascii: ":"), 2) : (UInt8(ascii: "/"), 1)

            guard written + mark.1 <= staged.count else {
                clear()
                return TextResult(.bufferTooSmall)
            }

            for _ in 0..<mark.1 {
                guard append(mark.0) else {
                    clear()
                    return TextResult(.bufferTooSmall)
                }
            }

            let named = appendName(node)
            guard named == .ok else {
                clear()
                return TextResult(named)
            }
        }

        guard capacity >= written else {
            clear()
            return TextResult(.bufferTooSmall)
        }

        let out = destination.assumingMemoryBound(to: UInt8.self)
        for index in 0..<written { out[index] = staged[index] }

        return TextResult(.ok, written)
    }


    public mutating func path(
        of     object     : UInt32,
        within root       : UInt32,
        into   destination: UnsafeMutableRawPointer,
               capacity   : Int
    ) -> Int {
        pathResult(of: object, within: root, into: destination, capacity: capacity).length
    }


    /// How a container stands: what it may use and what it is using.
    public mutating func roomResult(of container: UInt32) -> RoomResult {

        switch readObject(container) {
            case .live(let record):
                guard record.kind == .container else { return RoomResult(.wrongKind) }
                return RoomResult(.ok, (record.quota, record.used, record.roomLeft))

            case .free, .outside:
                return RoomResult(.notFound)

            case .failed(let why):
                return RoomResult(why)

            case .corrupt:
                return RoomResult(.quarantined)
        }
    }


    public mutating func room(of container: UInt32) -> (
        quota: UInt32,
        used : UInt32,
        left : UInt32
    )? {
        roomResult(of: container).value
    }


    // MARK: - Charging

    /// Books `blocks` against the container `index` belongs to, or refuses.
    ///
    /// Called before the blocks are taken from the bitmap, so a container over
    /// its room costs a comparison rather than an allocation and a rollback.
    mutating func charge(
        _  blocks: UInt32,
        to index : UInt32
    ) -> FSStatus {

        guard blocks > 0 else { return .ok }

        guard let place = charged(index), var container = object(place) else {
            // A disk that has stopped answering reads as "there is no such
            // object", and saying so would send the caller looking for a bug in
            // its own numbers.
            return explain(.notFound)
        }

        guard container.roomLeft >= blocks else { return .noSpace }

        // Checked, though the guard above already bounds it: the two lines are
        // one step apart and the guard reads a number off the disk. A record
        // that lies about its quota would otherwise turn this into a trap.
        let (spent, over) = container.used.addingReportingOverflow(blocks)
        guard !over else { return .noSpace }

        container.used = spent

        return store(container, at: place)
    }


    /// Gives `blocks` back to the container `index` belongs to.
    ///
    /// Nothing to give back is success; not being able to find out which
    /// container to give it to is not, and it used to be indistinguishable - a
    /// container that never recovers its room looks exactly like one that had
    /// none taken.
    ///
    /// A status and no longer a `Bool`, because the three ways this fails are
    /// three different facts: the record would not read, the volume is held
    /// still, the transaction has no room for another image. Every one of them
    /// used to arrive at the caller as the same `false`, and every caller turned
    /// that `false` into `ok`.
    ///
    /// And a container asked to take back more than it was ever charged holds the
    /// volume rather than being normalised to zero. Clamping wrote the *result*
    /// of the contradiction back to the medium: the number that would have shown
    /// something was wrong is the number that got overwritten.
    mutating func refund(
        _  blocks: UInt32,
        to index : UInt32
    ) -> FSStatus {

        guard blocks > 0 else { return .ok }
        guard let place = charged(index) else { return explain(.notFound) }

        return refund(blocks, toContainer: place)
    }


    /// Gives `blocks` back to a container the caller has already worked out.
    ///
    /// Separate from `refund` because the record that says which container an
    /// object belongs to may be gone by the time its blocks are given back:
    /// releasing an object publishes the free record first, on purpose, and a
    /// freed record cannot be asked where it lived. Asking afterwards silently
    /// gave nothing back, which is a container that never recovers its room.
    mutating func refund(
        _           blocks: UInt32,
        toContainer place : UInt32
    ) -> FSStatus {

        guard blocks > 0 else { return .ok }
        guard var container = object(place) else { return explain(.notFound) }

        // Checked, and no longer clamped to zero. See the doc above.
        let (left, under) = container.used.subtractingReportingOverflow(blocks)

        guard !under else {
            quarantine()
            return .quarantined
        }

        container.used = left

        return store(container, at: place)
    }
}
