//
//  GenerationTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// A capability naming an object that has since been removed.
///
/// The sequence this closes, in four steps: a process is given a capability for
/// object twelve; the object is removed; slot twelve is handed to a new file,
/// perhaps in another container; and the old capability now names that file. It
/// broke identity and isolation at once, and it needed no crash and no race -
/// only a remove and a create, in that order.
///
/// A slot number is not an identity. What makes one is the slot plus the count
/// of how many objects have passed through it, and the count has to be on the
/// disk and has to outlive the record it describes.
@Suite("A capability names a thing, not a slot")
struct GenerationTests {

    private static let sectors: UInt64 = 4096   // 2 MiB


    private func withDisk(_ body: (inout FileSystem<MemoryDisk>) -> Void) {
        let disk = MemoryDisk(sectors: Self.sectors)

        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes,
            alignment: 8
        )
        defer { scratch.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: scratch).disk else {
            Issue.record("the fixture disk would not format")
            return
        }

        body(&fs)
    }


    private func make(
        _ fs: inout FileSystem<MemoryDisk>,
        _ name: StaticString,
        kind: FSKind = .file,
        in folder: UInt32 = FSLayout.rootObject
    ) -> UInt32? {
        let made = fs.create(
            UnsafeRawPointer(name.utf8Start),
            length: name.utf8CodeUnitCount,
            kind  : kind,
            in    : folder
        )
        guard made.status == .ok else {
            Issue.record("the fixture object would not be made")
            return nil
        }
        return made.object
    }


    private func drop(
        _ fs: inout FileSystem<MemoryDisk>,
        _ name: StaticString,
        in folder: UInt32 = FSLayout.rootObject
    ) -> FSStatus {
        fs.remove(
            UnsafeRawPointer(name.utf8Start),
            length: name.utf8CodeUnitCount,
            from  : folder
        )
    }


    // MARK: - The sequence itself

    @Test("a capability for a removed object does not name whatever takes its slot")
    func theSlotIsReusedAndTheCapabilityIsNot() {
        withDisk { fs in
            let layout = FSBadge(objectCount: fs.plan.objectCount)

            guard let first = make(&fs, "first.txt"),
                  let record = fs.object(first)
            else { return }

            // Step one: somebody is handed a capability for this object.
            let handed = layout.encode(
                object: first, generation: record.generation, rights: .occupant
            )
            #expect(layout.object(of: handed) == first)

            // Step two: the object is removed.
            #expect(drop(&fs, "first.txt") == .ok)

            // Step three: the slot is handed to a different file. The hint makes
            // this the expected behaviour rather than a coincidence, and the
            // test says so out loud - a reuse that did not happen would make
            // everything below vacuous.
            guard let second = make(&fs, "second.txt") else { return }
            #expect(second == first, "the slot was not reused, so this proves nothing")

            guard let taken = fs.object(second) else {
                Issue.record("the new object is not there")
                return
            }

            // Step four, which no longer follows: the old capability names a
            // slot whose count has moved on.
            #expect(!layout.names(generation: taken.generation, badge: handed))
        }
    }


    @Test("a capability dies with its object, not with its slot")
    func removalIsEnough() {
        // Stronger than the sequence above, and the reason the count is bumped
        // on release rather than on the next allocation: the capability stops
        // working the moment the object goes, whether or not anybody is ever
        // given its slot.
        withDisk { fs in
            let layout = FSBadge(objectCount: fs.plan.objectCount)

            guard let object = make(&fs, "gone.txt"),
                  let before = fs.object(object)
            else { return }

            let handed = layout.encode(
                object: object, generation: before.generation, rights: .occupant
            )

            #expect(drop(&fs, "gone.txt") == .ok)

            guard let after = fs.object(object) else {
                Issue.record("the slot is not readable")
                return
            }

            #expect(after.kind == .free)
            #expect(!layout.names(generation: after.generation, badge: handed))
        }
    }


    @Test("crossing a container boundary is exactly what it used to allow")
    func theReusedSlotCanBeSomebodyElses() {
        // The half of this that mattered most. A capability handed out for a
        // file in one container could come to name a file in another, because
        // the slot table is shared by the whole disk and a number says nothing
        // about where it lives.
        withDisk { fs in
            let layout = FSBadge(objectCount: fs.plan.objectCount)

            let name = "vault" as StaticString
            let room = fs.createContainer(
                UnsafeRawPointer(name.utf8Start),
                length: name.utf8CodeUnitCount,
                quota : 32,
                in    : FSLayout.rootObject
            )
            guard room.status == .ok else {
                Issue.record("the fixture container would not be made")
                return
            }
            let vault = room.object

            guard let mine = make(&fs, "mine.txt") else { return }

            guard let record = fs.object(mine) else { return }
            let handed = layout.encode(
                object: mine, generation: record.generation, rights: .occupant
            )

            #expect(drop(&fs, "mine.txt") == .ok)

            guard let theirs = make(&fs, "theirs.txt", in: vault) else { return }
            #expect(theirs == mine, "the slot was not reused, so this proves nothing")

            guard let other = fs.object(theirs) else { return }

            // It is in a different container, and the old capability does not
            // reach it. Either half alone would not be enough: the containment
            // check reads the *record*, and the record is the new file's.
            #expect(other.container != record.container)
            #expect(!layout.names(generation: other.generation, badge: handed))
        }
    }


    @Test("the machine's own container keeps the capability handed out at boot")
    func theRootSurvives() {
        // The other direction: this must not invalidate anything. Init is given
        // one capability for object zero at mount and holds it for the life of
        // the machine, so a count that moved under it would take the whole disk
        // away.
        withDisk { fs in
            let layout = FSBadge(objectCount: fs.plan.objectCount)

            guard let root = fs.object(FSLayout.rootObject) else { return }
            let handed = layout.encode(
                object: FSLayout.rootObject, generation: root.generation, rights: .occupant
            )

            guard make(&fs, "a.txt") != nil, make(&fs, "b.txt") != nil else { return }
            #expect(drop(&fs, "a.txt") == .ok)

            guard let again = fs.object(FSLayout.rootObject) else { return }

            #expect(layout.names(generation: again.generation, badge: handed))
            #expect(layout.object(of: handed) == FSLayout.rootObject)
        }
    }


    @Test("the count survives a remount, because it is on the disk")
    func theCountIsPersistent() {
        let disk = MemoryDisk(sectors: Self.sectors)

        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
        defer { scratch.deallocate() }

        guard var first = FileSystem.format(disk, scratch: scratch).disk else {
            Issue.record("the fixture disk would not format")
            return
        }

        guard let object = make(&first, "once.txt") else { return }
        #expect(drop(&first, "once.txt") == .ok)

        guard let freed = first.object(object) else { return }
        let bumped = freed.generation
        #expect(bumped > 0)
        #expect(first.unmount() == .ok)

        guard var again = FileSystem.mount(disk, scratch: scratch).disk else {
            Issue.record("the disk would not mount again")
            return
        }

        // A count kept in memory would be back to zero here, and every
        // capability from the last boot would work again.
        #expect(again.object(object)?.generation == bumped)
    }


    // MARK: - The layout of the word

    @Test("the object takes the bits it needs and the count takes the rest")
    func theSplitFollowsTheDisk() {
        // Not a constant, because the disk says how many slots there are. The
        // numbers here are the ones that matter: this format's own 16 MiB disk,
        // and the shape of the degradation on a big one.
        let small = FSBadge(objectCount: 512)
        #expect(small.objectBits == 10)

        // Capped: the object number cannot grow into the rights, so a disk this
        // wide gets every bit under them and the generation gets none. See
        // "the generation still spans enough reuses of one slot".
        let big = FSBadge(objectCount: 1 << 24)
        #expect(big.objectBits == 24)

        // Whatever the split, the extremes have to survive the round trip.
        for layout in [small, big] {
            let top = layout.encode(object: 0, generation: 0, rights: .everything)
            #expect(layout.object(of: top) == 0)
            #expect(layout.generation(of: top) == 0)
            #expect(top != 0)
        }
    }


    @Test("a handle is the same word as a badge, minus the authority it does not carry")
    func handlesAreBadgesWithoutTheBit() {
        // What travels in a message when a client is answered "this object". It
        // had the badge's problem and now has the badge's answer, in the word it
        // already occupied: the object number is ten bits on this disk and the
        // word is thirty-two.
        let layout = FSBadge(objectCount: 512)

        for object in [UInt32(0), 1, 511] {
            for generation in [UInt32(0), 9, 1 << 20] {
                let handle = layout.handle(object: object, generation: generation)

                #expect(layout.object(of: handle) == object)
                #expect(layout.names(generation: generation, badge: handle))

                // A client answered nought has been answered nothing, and
                // sending nought back gets nothing too. That is what makes it
                // usable as "not set yet".
                #expect(handle != 0)

                // No rights: those belong to capabilities, and a handle in a
                // message carries no authority of its own.
                #expect(FileOperation.rights(badge: handle).isEmpty)

                // And the thing this exists for.
                #expect(!layout.names(generation: generation &+ 1, badge: handle))
            }
        }

        #expect(layout.object(of: 0) == nil)
    }


    @Test("a count wider than the badge is cut down, and the limit is known")
    func theLimitIsStated() {
        // Said out loud rather than left to be discovered: the comparison is
        // made on as much of the count as a badge can carry, so it takes that
        // many removals of one slot before an old capability could match again.
        // On this disk that is two million, which is the honest answer for a
        // thirty-two bit word and not a claim of never.
        let layout = FSBadge(objectCount: 512)

        let inside  = UInt32((1 << 21) - 1)
        let wrapped = inside &+ 1

        let badge = layout.encode(object: 3, generation: inside, rights: .occupant)

        #expect(layout.names(generation: inside, badge: badge))
        #expect(!layout.names(generation: wrapped, badge: badge))

        // And the wrap itself, which is the limit rather than a bug.
        #expect(layout.fits(wrapped) == 0)
        #expect(layout.fits(UInt32(1 << 21)) == layout.fits(0))
    }
}
