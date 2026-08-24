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

    /// How deep the containers may nest before a walk is treated as a loop.
    ///
    /// A corrupt disk can point a container at its own descendant, and a walk
    /// up such a chain never ends. A depth limit turns that into a refusal.
    static var nestingLimit: Int { 32 }


    /// The container an object's blocks are charged to.
    ///
    /// A container is charged to itself, which is what makes `charged` usable
    /// as "the place this thing is" without the caller having to ask what kind
    /// of thing it is first.
    public mutating func charged(_ index: UInt32) -> UInt32? {
        guard let record = object(index), record.kind != .free else { return nil }

        return record.kind == .container ? index : record.container
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
                  start.kind != .free else { return false }
        
        guard index != root else { return true }

        var here  = start.parent
        var depth = 0

        while depth < Self.nestingLimit {
            if here == root { return true }

            guard let record = object(here), record.kind != .free else { return false }

            // The machine's own root is its own parent, and that is where every
            // walk ends. The depth limit would end it anyway; this is speed.
            if record.parent == here { return false }

            here   = record.parent
            depth += 1
        }

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

        guard let parent = charged(folder) else { return (.notFound, 0) }
       
        guard var owner  = object(parent),
                  owner.kind == .container else {
            return (.wrongKind, 0)
        }

        guard owner.roomLeft >= quota else { return (.noSpace, 0) }

        let made = create(name, length: length, kind: .container, in: folder)
        guard made.status == .ok else { return (made.status, 0) }

        // Re-read: `create` may have grown the folder, which charges the parent
        // and would make a copy taken before it stale.
        guard var refreshed = object(parent) else { return (.notFound, 0) }

        guard refreshed.roomLeft >= quota else {
            _ = remove(name, length: length, from: folder)
            return (.noSpace, 0)
        }

        refreshed.quota -= quota
        guard store(refreshed, at: parent) == .ok else { return (.deviceFailed, 0) }

        guard var fresh = object(made.object) else { return (.notFound, 0) }
        fresh.quota     = quota
        fresh.container = parent

        guard store(fresh, at: made.object) == .ok else { return (.deviceFailed, 0) }

        _ = owner   // the pre-create copy is deliberately not used again

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

        guard var giver = object(parent),
                  giver.kind == .container else { return .wrongKind }
        
        guard var taker = object(child),
                  taker.kind == .container else { return .wrongKind }
        
        guard taker.container == parent else { return .notFound }

        guard giver.roomLeft >= blocks else { return .noSpace }

        let (given, over) = taker.quota.addingReportingOverflow(blocks)
        guard !over else { return .noSpace }

        giver.quota -= blocks // `roomLeft >= blocks` above makes this safe
        taker.quota  = given

        guard store(giver, at: parent) == .ok else { return .deviceFailed }

        return store(taker, at: child)
    }


    /// What an object is called, written into `destination`.
    ///
    /// Nothing on this disk has a name of its own: the name is the entry in the
    /// folder that points at it, which is why this is a scan and not a field.
    /// The machine's root is the exception, because nothing points at it, and
    /// it carries its name in the superblock instead.
    public mutating func name(
        of   container  : UInt32,
        into destination: UnsafeMutableRawPointer
    ) -> Int {

        guard container != FSLayout.rootObject else {
            return machineName(into: destination)
        }

        guard let record = object(container),
                  record.kind != .free else { return 0 }

        var length = 0
        let out    = destination.assumingMemoryBound(to: UInt8.self)

        forEachEntry(in: record.parent) { entry, _, _ in
            guard length == 0, entry.object == container else { return }

            for index in 0..<Int(entry.length) { out[index] = entry.name[index] }
            length = Int(entry.length)
        }

        return length
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
    public mutating func relocate(
        _      name     : UnsafeRawPointer,
               length   : Int,
        from   folder   : UInt32,
        to     target   :  UInt32,
        as     newName  : UnsafeRawPointer,
        length newLength: Int
    ) -> FSStatus {

        guard let object = lookup(name, length: length, in: folder) else { return .notFound }
        guard object != FSLayout.rootObject else { return .wrongKind }

        guard let destination = self.object(target), destination.kind != .file else {
            return .wrongKind
        }

        guard charged(folder) == charged(target) else { return .wrongKind }

        // Into itself, or into something inside itself.
        guard target != object, !contains(target, within: object) else { return .wrongKind }

        // Nothing to do, and doing it anyway would unlink and relink the same
        // entry, which is a window where it exists nowhere.
        if folder == target, FSEntry(object: object, name: newName, length: newLength)?
            .matches(name, length: length) == true {
            return .ok
        }

        guard lookup(newName, length: newLength, in: target) == nil else { return .exists }

        guard let entry = FSEntry(object: object, name: newName, length: newLength) else {
            return .badName
        }

        // Three writes, in the one order whose every stopping point leaves
        // something true. Linked first, so a failure in between leaves the thing
        // reachable by two names rather than by none. Then the parent, which is
        // what containment is read from, so it is moved while both names exist
        // rather than while only one does. Unlinked last.
        //
        // A crash after the first write leaves a stray name in the new folder
        // and the object still living in the old one; after the second, a stray
        // name in the old folder and the object living in the new one. Either is
        // a duplicate name to be tidied. The old order had a third outcome,
        // between the unlink and the parent, where the object was reachable only
        // from a folder it did not claim to be in - and containment is checked
        // by walking parents, so that object was reachable by name and refused
        // by right.
        let linked = link(entry, in: target)
        guard linked == .ok else { return linked }

        guard var record = self.object(object) else { return .notFound }
        record.parent   = target
        record.modified = now

        let moved = store(record, at: object)
        guard moved == .ok else { return moved }

        guard barrier() == .ok else { return .deviceFailed }

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

        guard readBlock(0, into: metaBuffer) == .ok else { return .deviceFailed }

        let letters = metaBuffer.advanced(by: Field.name).assumingMemoryBound(to: UInt8.self)

        for index in 0..<FSLayout.machineNameLimit {
            letters[index] = index < length ? bytes[index] : 0
        }

        return writeBlock(0, from: metaBuffer)
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
    public mutating func path(
        of     object     : UInt32,
        within root       : UInt32,
        into   destination: UnsafeMutableRawPointer,
               capacity   : Int
    ) -> Int {

        var chain = InlineArray<32, UInt32>(repeating: 0)
        var depth = 0
        var here  = object

        // Up to the root, remembering the way. The root itself is not in the
        // chain: its name is written first and everything else hangs off it.
        while here != root {
            guard depth < chain.count,
                  let record = self.object(here),
                  record.kind != .free,
                  record.parent != here
            else { return 0 }

            chain[depth] = here
            depth += 1
            here   = record.parent
        }

        let out = destination.assumingMemoryBound(to: UInt8.self)
        var written = name(of: root, into: destination)

        // Back down, writing a separator and then a name for each step.
        var step = depth
        while step > 0 {
            step -= 1

            let node = chain[step]
            let mark: (UInt8, Int) = self.object(node)?.kind == .container
                ? (UInt8(ascii: ":"), 2)
                : (UInt8(ascii: "/"), 1)

            guard written + mark.1 < capacity else { return written }

            for _ in 0..<mark.1 {
                out[written] = mark.0
                written += 1
            }

            let length = name(
                of  : node,
                into: destination.advanced(by: written)
            )

            guard length > 0, written + length <= capacity else { return written }

            written += length
        }

        return written
    }


    /// How a container stands: what it may use and what it is using.
    public mutating func room(of container: UInt32) -> (
        quota: UInt32,
        used : UInt32,
        left : UInt32
    )? {
        guard let record = object(container), record.kind == .container else { return nil }

        // The difference comes from here rather than being worked out by the
        // caller, so that the one place that knows how to subtract these two
        // safely is the only place that does.
        return (record.quota, record.used, record.roomLeft)
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
    mutating func refund(
        _  blocks: UInt32,
        to index : UInt32
    ) {

        guard blocks > 0, let place = charged(index) else { return }

        refund(blocks, toContainer: place)
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
    ) {

        guard blocks > 0, var container = object(place) else { return }

        container.used = container.used >= blocks ? container.used - blocks : 0

        _ = store(container, at: place)
    }
}
