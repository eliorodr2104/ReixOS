//
//  FileSystemServer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Reix
import ReixFS

/// The one process that knows what is on the disk.
///
/// It holds a block client and nothing else of consequence: no window on the
/// hardware and no interrupt. What it holds instead is the volume - claimed
/// once, at startup, from the block server - and the only mounted copy of the
/// format. The first of those is why nobody can write a sector underneath it;
/// the second is why nobody else knows what a sector means.
///
/// Clients name things and get bytes. Where those bytes are, which blocks are
/// free, and what a folder is made of never leave this process.
public struct FileSystemServer: Service {

    /// It publishes nothing.
    ///
    /// A name in the name server is a thing anybody may look up, and a file
    /// system anybody may look up is a file system everybody is inside. What
    /// this server hands out instead is one capability, to its parent, bound to
    /// the machine's own container - and every other view of the disk is carved
    /// out of that one by somebody who already had it.
    public static let manifest = ServiceManifest(provides: .none)

    private static let capacity     = 8
    private static let pageSize     : UInt64 = 4096
    /// The widest window a client may attach.
    ///
    /// Four pages, so that one read can span enough blocks for the disk to be
    /// asked for several of them at once. It was one, which capped every transfer
    /// at a page and therefore at two blocks - and two is not a pipeline.
    private static let maximumPages : UInt32 = 4

    /// The file system's scratch blocks: two to work in and four it holds.
    ///
    /// Allocated rather than declared as a static array: taking the address of
    /// a global and keeping it is a thing Swift does not promise, and twenty-four
    /// kilobytes is far too much to put on a sixteen-kilobyte stack.
    private static func scratch() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<BlockClient>.scratchBytes,
            alignment: 8
        )
    }

    private let endpoint: UInt32
    private var disk    : FileSystem<BlockClient>

    /// How this disk's badges are laid out, which depends on how many object
    /// slots it has. Worked out once, at mount, because it cannot change while
    /// a disk is mounted and every request reads a badge.
    private let badgeLayout: FSBadge

    /// The handle layout that goes with it.
    ///
    /// Two layouts and not one, because a handle travels in a message word and a
    /// badge travels in the session register: one is thirty-two bits wide and the
    /// other sixty-four. Sharing an encoding made the badge as narrow as the
    /// handle, and the generation paid for it. See `FSHandle`.
    private let handleLayout: FSHandle

    /// Cleared by `unmount`, and never set again.
    ///
    /// A disk marked clean and then written to would be a disk whose mark is a
    /// lie, and the mark is the whole of this format's crash safety. So the
    /// last thing anybody says to this server really is the last thing: after
    /// it, every request answers that there is no file system here.
    private var mounted = true

    /// Whether the medium is clean and the block server still has the claim.
    ///
    /// The one state this process cannot leave on its own: nothing more may be
    /// written, and the disk is not free either. Said out loud once per attempt
    /// and retried on the next, and it is a warden's `reclaim` that ends it.
    private var heldVolume = false

    /// Who is in the middle of writing what.
    ///
    /// Eight claims, each an object and the client holding it. A write of one
    /// request needs none of this: there is one thread and nothing yields in
    /// the middle. What needs it is a write that takes several requests, where
    /// somebody else's request can land between two of yours - and no amount of
    /// care inside one operation prevents that.
    ///
    // TODO: - when there are threads this table becomes the real lock and the
    // waiting becomes blocking rather than a refusal. The shape is already the
    // shape it wants: an object, an owner, and an answer for everybody else.
    private var leases = FSLeases()

    /// The window each client attached, one slot each.
    ///
    /// One value where there were four parallel arrays, and the replacement rule
    /// is why: `install` hands back whatever it displaced, in one store, so a
    /// slot is never momentarily empty and a window cannot be overwritten without
    /// the old one coming back to be unmapped. Attaching again used to *release
    /// first* and map afterwards, so a client whose second attach failed at the
    /// mapping was left with no window at all - its first one already gone. See
    /// `ShmAttachment.Slot`.
    private var attachments: InlineArray<8, ShmAttachment.Slot> = InlineArray(
        repeating: ShmAttachment.Slot()
    )

    public var serviceEndpoint: UInt32 { endpoint }

    /// Where slot `slot`'s window starts in this process, or nothing when the
    /// slot holds none.
    private func window(_ slot: Int) -> UnsafeMutableRawPointer? {
        guard let held = attachments[slot].current else { return nil }

        return UnsafeMutableRawPointer(bitPattern: UInt(held.address))
    }

    /// How far that window reaches. Zero when there is none, which every bound
    /// below then refuses on.
    private func extent(_ slot: Int) -> UInt64 {
        attachments[slot].current?.extent ?? 0
    }


    public init(
          environment: Environment,
          endpoint   : UInt32
    ) {

        self.endpoint = endpoint

        // Handed over, not looked up. There is no name for the disk, so the only
        // way this process reaches one is that whoever started it decided to
        // give it one, once.
        guard let block = environment.block else {
            print("[ FS    ] no disk was handed to this process")
            Self.stop()
        }

        guard let device = BlockClient(block: block) else {
            print("[ FS    ] the disk would not attach")
            Self.stop()
        }

        // The volume before the format. From here this process is the only one
        // whose writes the block server will carry out, which is what turns
        // "the file system is the arbiter of the disk" from a convention in
        // this file into a refusal in another process.
        guard device.mount() == .ok else {
            print("[ FS    ] the volume is held by somebody else")
            Self.stop()
        }

        print("[ FS    ] disk found, mounting")

        // One scratch allocation, used by whichever of the two doors is taken.
        let scratch = Self.scratch()

        let attempt = FileSystem.mount(device, scratch: scratch)

        guard let disk = attempt.disk ?? Self.formatIfBlessed(
            attempt.found,
            device : device,
            scratch: scratch
        ) else {
            Self.stop()
        }

        self.disk   = disk
        self.badgeLayout  = FSBadge(objectCount: disk.plan.objectCount)
        self.handleLayout = self.badgeLayout.handles

        // Said once, loudly, and before the room is reported: everything below
        // this line is still readable and none of it will change.
        if self.disk.corrupted {
            print("[ FS    ] this disk contradicted itself, so it is now read-only")
        }

        let free = self.disk.freeBlocksResult()
        guard free.status == .ok else { Self.stop() }

        print("[ FS    ] mounted, ", terminator: "")
        printDec(UInt64(free.value), terminator: "")
        print(" blocks free", terminator: "")
        print(self.disk.wasDirty ? ", disk was not unmounted cleanly" : ", clean")

        handRootToParent()
    }


    /// Stops, having first told whoever started this process that there will be
    /// no file system.
    ///
    /// Every way out of the way up has to say it. The parent is waiting on this
    /// endpoint for the machine's container, and a service that dies quietly
    /// leaves it waiting - which, on a machine whose disk cannot be read, means
    /// no shell at exactly the moment somebody wants one.
    ///
    /// Offered rather than delivered, for the same reason a pipe's end marker
    /// is: a parent that has already given up waiting must not be able to hold
    /// this process here on the way out.
    private static func stop() -> Never {

        if let parent = parentEndpoint() {
            _ = trySend(handle: parent, message: BootMessage.refused.message)
        }

        exit(code: 1)
    }


    private static func encodeScrub(
        _ findings: FileSystem<BlockClient>.Findings,
        into window: UnsafeMutableRawPointer,
        capacity: Int
    ) -> Int {
        guard var writer = ShellFrameWriter(
            window.assumingMemoryBound(to: UInt8.self),
            capacity: capacity,
            schema: .fileSystemFindings,
            sequence: 0,
            flags: findings.safeToServe ? [.end] : [.end, .error]
        ) else { return 0 }
        func append(
            _ field: ShellField,
            _ value: UInt32
        ) -> Bool {
            writer.appendScalar(field == .status ? .status : .scalar, field: field, value: value)
        }
        guard append(.status, findings.safeToServe ? FSStatus.ok.rawValue : FSStatus.deviceFailed.rawValue),
              append(.complete, findings.complete ? 1 : 0),
              append(.scrubDepth, findings.depth == .everything ? 1 : 0),
              append(.quotasChecked, findings.quotasChecked ? 1 : 0),
              append(.reclaimableBlocks, findings.reclaimable), append(.ownedButFree, findings.ownedButFree),
              append(.claimedTwice, findings.claimedTwice), append(.impossible, findings.impossible),
              append(.strayNames, findings.strayNames), append(.duplicateNames, findings.duplicateNames),
              append(.duplicateTargets, findings.duplicateTargets), append(.brokenEntries, findings.brokenEntries),
              append(.nameScrubBudgetExhausted, findings.nameScrubBudgetExhausted ? 1 : 0),
              append(.wrongQuota, findings.wrongQuota), append(.strayCharges, findings.strayCharges),
              append(.selfParented, findings.selfParented), append(.roomsMended, findings.roomsMended),
              append(.mapMended, findings.mapMended ? 1 : 0), append(.tooManyContainers, findings.tooManyContainers ? 1 : 0),
              append(.safeToServe, findings.safeToServe ? 1 : 0)
        else { return 0 }
        return writer.finish()
    }


    /// What to do about a disk that would not mount.
    ///
    /// Only one of the five refusals is a disk anybody may write over, and even
    /// that one is not this process's to decide about: it asks whoever started
    /// it and formats only if the answer is yes. Everything else is reported and
    /// left exactly as it was found, down to the byte. There is no path from
    /// here to `format` that a disk can take by being unreadable.
    private static func formatIfBlessed(
        _ found: FSMount,
          device : BlockClient,
          scratch: UnsafeMutableRawPointer
    ) -> FileSystem<BlockClient>? {

        switch found {
            case .ok:
                // Mounted, so this was never called. Here for the compiler.
                return nil

            case .deviceFailed:
                print("[ FS    ] the disk stopped answering while it was being read")
                return nil

            case .unusable:
                print("[ FS    ] the disk cannot hold a file system")
                return nil

            case .tooLarge(let blocks):
                // Not read, and not formatted. A dirty mount runs a recovery
                // whose cost grows with the square of the disk, so a geometry
                // this build has not measured is one it cannot promise a boot
                // comes back from. See `FSLayout.maxSupportedBlocksV02`.
                print("[ FS    ] this disk is ", terminator: "")
                printDec(UInt64(blocks), terminator: "")
                print(" blocks, more than this build is declared to serve, so nothing was read")
                return nil

            case .durabilityUnknown:
                // Not a broken disk and not an unreadable one. The device works
                // and will not say what a completed write achieves, so there is
                // no order to be had on it, and this format is nothing but an
                // order. Formatting would be the one thing that must not happen.
                print("[ FS    ] the disk will not say what a finished write achieves, so nothing was written")
                return nil

            case .corrupt:
                // Not touched, and this is the whole correction: a superblock
                // that does not add up used to be formatted, so a torn write or
                // another system's disk was erased for looking unfamiliar.
                print("[ FS    ] there is something on this disk and it is not a file system this build can mount, so nothing was written")
                return nil

            case .unsupportedVersion(let version):
                // Printed as the two letters it is, not as the number those
                // letters happen to make: the disk says `REIXFS` and then this,
                // so this is what somebody reading a hex dump will be looking
                // for.
                print("[ FS    ] this disk says it is format version ", terminator: "")
                putchar(ch: readable(UInt8(truncatingIfNeeded: version)))
                putchar(ch: readable(UInt8(truncatingIfNeeded: version >> 8)))
                print(", which this build cannot read, so nothing was written")
                return nil

            case .blank:
                guard askedToFormat() else {
                    print("[ FS    ] the disk is empty and nobody said to format it")
                    return nil
                }

                print("[ FS    ] the disk is empty, formatting as asked")

                let made = FileSystem.format(device, scratch: scratch)

                guard let disk = made.disk else {
                    print("[ FS    ] the disk could not be formatted")
                    return nil
                }

                return disk
        }
    }


    /// Asks whoever started this process whether an empty disk may be formatted.
    ///
    /// A question and not a notice, so the answer can be no. The parent is the
    /// process that handed this one the disk in the first place, which is what
    /// makes it the one entitled to say.
    private static func askedToFormat() -> Bool {

        guard let parent = parentEndpoint() else { return false }

        // A reply that never came is a no, which is the right way round: the
        // only outcome of not being told to format is not formatting.
        guard case .success(let answer) = call(
            handle : parent,
            message: BootMessage.blankDisk.message
        ) else { return false }

        return answer.message.tag.label == BootMessage.allowed.rawValue
    }


    /// Gives the machine's own container to whoever started this process.
    ///
    /// One capability, once. Everything anybody else ever holds of this disk is
    /// descended from it, which is what makes "who can see the whole disk" a
    /// question with an answer instead of a matter of who thought to ask.
    private mutating func handRootToParent() {

        guard let parent = parentEndpoint() else {
            print("[ FS    ] nobody to give the machine's container to")
            return
        }

        // Everything, and this is the only capability in the system that gets
        // it. Every other one is cut from this and can only be narrower, so the
        // question "who may unmount this volume" has an answer that starts here.
        guard let root = capability(for: FSLayout.rootObject, rights: .everything) else {
            print("[ FS    ] cannot mint the machine's container")
            return
        }

        // `BootMessage` and not a `FileOperation`, because this channel is the
        // parent's and speaks the parent's vocabulary. The capability is the
        // message; the words are not read at the other end.
        _ = send(
            handle     : parent,
            message    : BootMessage.announce.message,
            grant      : root,
            grantRights: [.send, .grant]
        )

        _ = capDrop(root)
    }


    /// A capability naming one object *as it is now*, bound so it cannot be
    /// rebound.
    ///
    /// The minted capability comes back without the right to derive, so its
    /// holder cannot mint a second naming somewhere else. That is not this
    /// server being careful: `CapsTable.mint` refuses to badge an already
    /// badged capability, and drops `derive` on the way out.
    ///
    /// "As it is now" is the generation, and it is read from the record rather
    /// than passed in: a capability is minted for a thing that exists, and the
    /// thing says which incarnation of its slot it is. Without it the capability
    /// would name a slot, and slots get handed on.
    mutating func capability(
        for object: UInt32,
        rights    : FSRights
    ) -> UInt32? {

        guard let record = disk.object(object), record.kind != .free else { return nil }

        return derive(
            handle : endpoint,
            session: badgeLayout.encode(
                object    : object,
                generation: record.generation,
                rights    : rights
            ),
            rights : [.send, .grant]
        )
    }


    /// The object a client's handle names, if it still names one.
    ///
    /// `nil` for a handle that was never valid and for one that has stopped
    /// being: the slot it names is free, or its count has moved on because the
    /// thing it was given for was removed. Either way the caller is told the
    /// same thing it would be told about a number it invented, which is nothing.
    ///
    /// Called on every object a request names, before anything else looks at it.
    /// It costs a record read, and the containment check that follows reads the
    /// same record again - worth knowing, and cheaper than a handle that quietly
    /// changes meaning.
    private mutating func resolve(_ handle: UInt32) -> UInt32? {

        guard let object = handleLayout.object(of: handle),
              let record = disk.object(object),
              record.kind != .free,
              handleLayout.names(generation: record.generation, handle: handle)
        else { return nil }

        return object
    }


    /// The handle to give a client for `object`, naming it as it is now.
    ///
    /// Zero when the object is not there, which is not a handle: a client that
    /// is answered zero has been answered nothing, and sending it back gets
    /// nothing too.
    private mutating func handle(for object: UInt32) -> UInt32 {

        guard let record = disk.object(object), record.kind != .free else { return 0 }

        return handleLayout.encode(object: object, generation: record.generation)
    }


    public mutating func handle(
        _ operation: FileOperation,
          request  : inout ReceivedMessage
    ) {
        if case .attach = operation {
            attach(&request)
            return
        }

        // The caller's container is read off the capability it used, on every
        // single request. Not stored at attach and not taken from the message:
        // a client cannot say which container it is in any more than it can say
        // who it is.
        //
        // And the *generation* is checked with it, every time, which is what
        // makes the capability name a thing rather than a slot. A capability for
        // an object that has since been removed names a slot whose count has
        // moved on, so it answers nothing - whether or not somebody else has
        // been given that slot in the meantime.
        guard let root = badgeLayout.object(of: request.session),
              let anchor = disk.object(root),
              anchor.kind != .free,
              badgeLayout.names(generation: anchor.generation, badge: request.session),
              slot(for: request.identity) != nil
        else {
            _ = reply(message: FileOperation.answer(.notFound))
            return
        }

        // What this capability may do, against what this operation needs. One
        // comparison, and the table it reads is `FSRights.required(for:)`, so
        // there is nowhere else an operation's price can be written down.
        //
        // The refusal names itself rather than hiding as `notFound`: the holder
        // was handed this deliberately, so being told what it cannot do reveals
        // nothing it was not already told by being given it.
        let held = FileOperation.rights(badge: request.session)

        guard held.contains(FSRights.required(for: operation)) else {
            _ = reply(message: FileOperation.answer(.readOnly))
            return
        }

        // `unmount` is the retry when the claim is still held, and refusing it
        // here made that recovery unreachable. See `unmountVolume`.
        guard mounted || (operation == .unmount && heldVolume) else {
            _ = reply(message: FileOperation.answer(.notFormatted))
            return
        }

        // Every request is one indivisible step. Nothing here yields in the
        // middle of an operation, so nobody can see a half-done one.
        //
        // TODO: - that is a property of there being one thread, not of the code
        // being careful. When threads arrive this loop wants a lock per object
        // and the operations that touch two things at once - `relocate` above
        // all - want to take both.
        disk.now = SystemClock.now().nanoseconds

        switch operation {
            case .attach:
                break

            case .status:
                let free: UInt32
                let used: UInt32

                if anchor.kind == .container {
                    let room = disk.roomResult(of: root)
                    guard room.status == .ok, let value = room.value else {
                        _ = reply(message: FileOperation.answer(room.status))
                        return
                    }
                    free = value.left
                    used = value.used
                } else {
                    // `status` is also the attach acknowledgement. A capability
                    // may root its holder at one file or folder, which has no
                    // room to delegate but is still a complete, usable view.
                    // Do not ask `roomResult` about it: room belongs only to
                    // containers, and a wrong-kind reply would discard a valid
                    // deliberately attenuated loan.
                    free = 0
                    used = 0
                }

                // The name of the caller's own root goes into its window,
                // terminated, so a path may be written starting from it. A
                // process is told what its world is called; it is never told
                // what anything above it is called.
                if let slot = slot(for: request.identity), let window = window(slot) {
                    let length = disk.name(of: root, into: window)
                    window.storeBytes(of: UInt8(0), toByteOffset: length, as: UInt8.self)
                }

                _ = reply(message: FileOperation.standing(
                    root       : handle(for: root),
                    free       : free,
                    used       : used,
                    dirty      : disk.wasDirty,
                    quarantined: disk.corrupted
                ))

            case .open, .create, .createContainer, .remove:
                named(operation, request: request, root: root)

            case .read, .write, .replace:
                bytes(operation, request: request, root: root)

            case .list:
                listing(request: request, root: root)

            case .bind:
                bind(request: request, root: root)

            case .grantRoom:
                grantRoom(request: request, root: root)

            case .path:
                written(request: request, root: root)

            case .info:
                describe(request: request, root: root)

            case .scrub:
                guard root == FSLayout.rootObject else {
                    _ = reply(message: FileOperation.answer(.notFound))
                    return
                }

                let findings = disk.scan(.everything)
                guard let slot = slot(for: request.identity), let window = window(slot),
                      let length = UInt32(exactly: Self.encodeScrub(
                        findings,
                        into: window,
                        capacity: Int(extent(slot))
                      )), length > 0
                else {
                    _ = reply(message: FileOperation.answer(.bufferTooSmall))
                    return
                }

                _ = reply(message: FileOperation.answer(
                    findings.safeToServe ? .ok : .deviceFailed,
                    value: length
                ))

            case .compact:
                guard let wanted = resolve(request.message.words[0]),
                      disk.contains(wanted, within: root)
                else {
                    _ = reply(message: FileOperation.answer(.notFound))
                    return
                }

                guard mayChange(wanted, request.identity) else {
                    _ = reply(message: FileOperation.answer(.busy))
                    return
                }

                _ = reply(message: FileOperation.answer(disk.compact(wanted)))

            case .lock:
                guard let wanted = resolve(request.message.words[0]) else {
                    _ = reply(message: FileOperation.answer(.notFound))
                    return
                }

                _ = reply(message: FileOperation.answer(
                    claim(wanted, for: request.identity, root: root)
                ))

            case .unlock:
                // A stale handle lets go of nothing, which matters more here
                // than elsewhere: a claim released by somebody holding an old
                // handle is a claim taken away from whoever holds it now.
                if let wanted = resolve(request.message.words[0]) {
                    release(wanted, from: request.identity)
                }

                _ = reply(message: FileOperation.answer(.ok))

            case .up:
                guard let wanted = resolve(request.message.words[0]),
                      disk.contains(wanted, within: root),
                      let record = disk.object(wanted)
                else {
                    _ = reply(message: FileOperation.answer(.notFound))
                    return
                }

                // At the edge of what the caller holds, up is where it already
                // is. There is nothing above it that it has a name for.
                let above = wanted == root ? root : record.parent

                _ = reply(message: FileOperation.answer(.ok, value: handle(for: above)))

            case .relocate:
                relocate(request: request, root: root)

            case .nameMachine:
                rename(request: request, root: root)

            case .unmount:
                guard root == FSLayout.rootObject else {
                    _ = reply(message: FileOperation.answer(.notFound))
                    return
                }

                _ = reply(message: FileOperation.answer(unmountVolume()))
        }
    }


    /// Marks the disk clean and hands the volume back, in that order.
    ///
    /// **Two steps, and the second used to be unwatched.** Marking the medium
    /// clean is one act; letting go of the claim at the block server is another,
    /// it can fail on its own, and its status was discarded - so a client told
    /// `ok` believed the disk was free while the block server still had it down
    /// as this process's. Nobody could mount it, nothing said why, and a claim
    /// nobody speaks for is exactly what a warden is for: `reclaim` frees one
    /// whether or not the holder is still running.
    ///
    /// The claim is retried on the next attempt, because it is the only half
    /// still outstanding: the medium is already clean, so `disk.unmount` is not
    /// asked again.
    private mutating func unmountVolume() -> FSStatus {

        if !heldVolume {
            let status = disk.unmount()
            guard status == .ok else { return status }

            mounted = false
        }

        let released = disk.device.unmount()

        guard released == .ok else {
            heldVolume = true

            print("[ FS    ] the disk is clean and the block server still holds the claim")
            return .busy
        }

        heldVolume = false

        print("[ FS    ] unmounted, the disk is clean")
        return .ok
    }


    /// Answers a capability for a container the caller can already reach.
    ///
    /// Refused for anything outside the caller's own container, and refused
    /// with `notFound` rather than a refusal of its own: telling a caller that
    /// something exists but is not theirs is telling them something.
    private mutating func bind(
          request: ReceivedMessage,
          root   : UInt32
    ) {

        // Anything the caller can reach: a container, a folder, or one file.
        // What it cannot do is widen. The rights asked for are intersected with
        // the ones it holds, so a share never grows on the way down and there is
        // no request anywhere in this protocol that hands out more authority
        // than the capability it arrived through.
        let asked = FSRights(rawValue: request.message.words[1])
        let given = asked.intersection(FileOperation.rights(badge: request.session))

        guard let wanted = resolve(request.message.words[0]),
              disk.contains(wanted, within: root),
              let handed = capability(for: wanted, rights: given)
        else {
            _ = reply(message: FileOperation.answer(.notFound))
            return
        }

        _ = reply(
            message    : FileOperation.answer(.ok, value: handle(for: wanted)),
            grant      : handed,
            grantRights: [.send, .grant]
        )

        _ = capDrop(handed)
    }


    /// Writes what an object is into the caller's window.
    private mutating func describe(
          request: ReceivedMessage,
          root   : UInt32
    ) {

        guard let slot = slot(for: request.identity), let window = window(slot) else {
            _ = reply(message: FileOperation.answer(.notFound))
            return
        }

        guard let wanted = resolve(request.message.words[0]),
              disk.contains(wanted, within: root),
              let record = disk.object(wanted),
              extent(slot) >= UInt64(FSInfo.width)
        else {
            _ = reply(message: FileOperation.answer(.notFound))
            return
        }

        FSInfo(
            kind    : record.kind,
            size    : record.size,
            blocks  : record.blocks,
            created : Time(nanoseconds: record.created),
            modified: Time(nanoseconds: record.modified)
        ).write(to: window)

        _ = reply(message: FileOperation.answer(.ok, value: UInt32(FSInfo.width)))
    }


    /// Gives something a new name, a new folder, or both.
    ///
    /// Both names arrive in the window, the old one first, because a name is
    /// bytes and bytes travel there. One request, so the thing is never
    /// nameless and never named twice from anybody else's point of view.
    private mutating func relocate(
          request: ReceivedMessage,
          root   : UInt32
    ) {

        guard let slot = slot(for: request.identity), let window = window(slot) else {
            _ = reply(message: FileOperation.answer(.notFound))
            return
        }

        let length    = Int(request.message.words[1])
        let newLength = Int(request.message.words[3])

        guard let folder = resolve(request.message.words[0]),
              let target = resolve(request.message.words[2])
        else {
            _ = reply(message: FileOperation.answer(.notFound))
            return
        }

        guard length > 0, newLength > 0,
              UInt64(length + newLength) <= extent(slot)
        else {
            _ = reply(message: FileOperation.answer(.badName))
            return
        }

        guard disk.contains(folder, within: root), disk.contains(target, within: root) else {
            _ = reply(message: FileOperation.answer(.notFound))
            return
        }

        // Three things change: the folder the name leaves, the folder it joins,
        // and the object, whose `parent` moves. A claim on any of them is a
        // claim against this.
        let moving = disk.lookup(UnsafeRawPointer(window), length: length, in: folder).object

        guard mayChangeAll(folder, target, moving, by: request.identity) else {
            _ = reply(message: FileOperation.answer(.busy))
            return
        }

        _ = reply(message: FileOperation.answer(disk.relocate(
            UnsafeRawPointer(window),
            length: length,
            from  : folder,
            to    : target,
            as    : UnsafeRawPointer(window.advanced(by: length)),
            length: newLength
        )))
    }


    /// Renames the machine, for a caller that holds the machine.
    private mutating func rename(
          request: ReceivedMessage,
          root   : UInt32
    ) {

        guard let slot = slot(for: request.identity), let window = window(slot),
              root == FSLayout.rootObject
        else {
            _ = reply(message: FileOperation.answer(.notFound))
            return
        }

        let length = Int(request.message.words[0])

        guard length > 0, UInt64(length) <= extent(slot) else {
            _ = reply(message: FileOperation.answer(.badName))
            return
        }

        _ = reply(message: FileOperation.answer(
            disk.setMachineName(UnsafeRawPointer(window), length: length)
        ))
    }


    /// Writes the path of an object into the caller's window.
    ///
    /// From the caller's own root and no higher. A path that started above it
    /// would be a name for a place it was never told about, which is the one
    /// thing this must not hand out.
    private mutating func written(
          request: ReceivedMessage,
          root   : UInt32
    ) {

        guard let slot = slot(for: request.identity), let window = window(slot) else {
            _ = reply(message: FileOperation.answer(.notFound))
            return
        }

        guard let wanted = resolve(request.message.words[0]) else {
            _ = reply(message: FileOperation.answer(.notFound))
            return
        }

        let path = disk.pathResult(
            of      : wanted,
            within  : root,
            into    : window,
            capacity: Int(extent(slot))
        )

        guard path.status == .ok else {
            _ = reply(message: FileOperation.answer(path.status))
            return
        }

        _ = reply(message: FileOperation.answer(.ok, value: UInt32(path.length)))
    }


    /// Moves room from the caller's container into one directly inside it.
    private mutating func grantRoom(
          request: ReceivedMessage,
          root   : UInt32
    ) {

        let blocks = request.message.words[1]

        guard let child = resolve(request.message.words[0]),
              disk.contains(child, within: root)
        else {
            _ = reply(message: FileOperation.answer(.notFound))
            return
        }

        // Room moves out of one container's record and into another's, so both
        // of them change and a claim on either is a claim against this.
        guard mayChangeAll(root, child, by: request.identity) else {
            _ = reply(message: FileOperation.answer(.busy))
            return
        }

        _ = reply(message: FileOperation.answer(
            disk.grantQuota(blocks, from: root, to: child)
        ))
    }


    // MARK: - Names

    private mutating func named(
        _ operation: FileOperation,
          request  : ReceivedMessage,
          root     : UInt32
    ) {
        guard let slot = slot(for: request.identity), let window = window(slot) else {
            _ = reply(message: FileOperation.answer(.notFound))
            return
        }

        guard let folder = resolve(request.message.words[0]),
              disk.contains(folder, within: root)
        else {
            _ = reply(message: FileOperation.answer(.notFound))
            return
        }
        let length = Int(request.message.words[1])
        let kind   = FSKind(rawValue: UInt8(truncatingIfNeeded: request.message.words[2])) ?? .file

        guard length > 0, UInt64(length) <= extent(slot) else {
            _ = reply(message: FileOperation.answer(.badName))
            return
        }

        let name = UnsafeRawPointer(window)

        switch operation {
            case .open:
                // Contained, again, on what came back: the folder being the
                // caller's does not make everything a name in it points at theirs.
                let found = disk.lookup(name, length: length, in: folder)

                guard case .at(let object) = found else {
                    _ = reply(message: FileOperation.answer(found.refusal))
                    return
                }

                guard disk.contains(object, within: root),
                      let record = disk.object(object)
                else {
                    _ = reply(message: FileOperation.answer(.notFound))
                    return
                }

                _ = reply(message: FileOperation.describing(
                    .ok,
                    object: handle(for: object),
                    kind  : record.kind,
                    size  : record.size
                ))

            case .create, .createContainer:
                // Which door this came through decides what may be made, and the
                // kind in the payload only says which of those it is. A container
                // asked for through `create` is refused here rather than being
                // made at the price of a file: the operation is what the rights
                // were checked against, and the word in the message is not.
                guard operation.makes(kind) else {
                    _ = reply(message: FileOperation.answer(.wrongKind))
                    return
                }

                // The folder is what changes here: an entry goes into it, and it
                // may take a block to hold one. A client part way through its own
                // several-request change to a folder has claimed exactly that.
                guard mayChange(folder, request.identity) else {
                    _ = reply(message: FileOperation.answer(.busy))
                    return
                }

                let made = operation == .createContainer
                    ? disk.createContainer(
                        name,
                        length: length,
                        quota : request.message.words[3],
                        in    : folder
                      )
                    : disk.create(name, length: length, kind: kind, in: folder)

                guard made.status == .ok else {
                    _ = reply(message: FileOperation.answer(made.status))
                    return
                }

                _ = reply(message: FileOperation.describing(
                    .ok,
                    object: handle(for: made.object),
                    kind  : kind,
                    size  : 0
                ))

            default:
                // Claimed by somebody else is claimed against removal too:
                // taking a file away while another process is writing it is
                // the same act as writing it underneath them. And the folder
                // changes as much as the thing does - the entry comes out of it.
                let target = disk.lookup(name, length: length, in: folder).object

                guard mayChange(folder, request.identity),
                      target.map({ mayChange($0, request.identity) }) ?? true
                else {
                    _ = reply(message: FileOperation.answer(.busy))
                    return
                }

                _ = reply(message: FileOperation.answer(
                    disk.remove(name, length: length, from: folder)
                ))
        }
    }


    /// As many of a folder's names as the caller's window holds, in one reply.
    ///
    /// Three bounds on how many, and the smallest wins: what the client asked
    /// for, how many entries fit in the window it actually attached, and the
    /// protocol's own limit. The middle one is not the client's word for it -
    /// `extents` comes from `shmPages`, so a client claiming a bigger window than
    /// it granted has this server writing into pages it does not have.
    private mutating func listing(
          request: ReceivedMessage,
          root   : UInt32
    ) {

        guard let slot = slot(for: request.identity), let window = window(slot) else {
            _ = reply(message: FileOperation.answer(.notFound))
            return
        }

        let cursor = request.message.words[1]

        guard let folder = resolve(request.message.words[0]),
              disk.contains(folder, within: root)
        else {
            _ = reply(message: FileOperation.answer(.notFound))
            return
        }

        // Three bounds, and the window is the one the client cannot argue with:
        // its size came from the kernel at attach, not from this message. A
        // window too small for one entry is refused the way a read too big for
        // it is, and `batchLimit` is what stops a request from walking an
        // unbounded amount of disk while everybody else waits.
        let fits  = Int(extent(slot)) / FSListEntry.width
        let asked = Int(request.message.words[2])

        guard fits > 0 else {
            _ = reply(message: FileOperation.answer(.noSpace))
            return
        }

        let allowed = min(min(asked, fits), FSListEntry.batchLimit)

        let found = disk.entries(
            from    : cursor,
            in      : folder,
            into    : window,
            capacity: allowed
        )

        // The file system wrote raw object indices, because that is what a
        // directory entry holds. A client is never given one: an index outlives
        // the object it named, and the next thing in that slot would answer to
        // it. So each is replaced by a handle before the reply goes out.
        for index in 0..<found.count {
            let at = window.advanced(by: index * FSListEntry.width)

            FSListEntry.rebadge(at, handle(for: FSListEntry.reference(of: at)))
        }

        _ = reply(message: FileOperation.listed(
            found.status,
            count: UInt32(found.count),
            next : found.next,
            eof  : found.eof
        ))
    }


    // MARK: - Bytes

    private mutating func bytes(
        _ operation: FileOperation,
          request  : ReceivedMessage,
          root     : UInt32
    ) {
        guard let slot = slot(for: request.identity), let window = window(slot) else {
            _ = reply(message: FileOperation.answer(.notFound))
            return
        }

        guard let object = resolve(request.message.words[0]),
              disk.contains(object, within: root)
        else {
            _ = reply(message: FileOperation.answer(.notFound))
            return
        }
        let offset = FileOperation.offset(of: request.message)
        let count  = UInt64(request.message.words[3])

        guard count <= extent(slot) else {
            _ = reply(message: FileOperation.answer(.noSpace))
            return
        }

        guard operation == .read || mayChange(object, request.identity) else {
            _ = reply(message: FileOperation.answer(.busy))
            return
        }

        let result: (status: FSStatus, bytes: UInt64)

        switch operation {
            case .read:
                result = disk.read(object, at: offset, into: window, count: count)

            case .replace:
                result = disk.write(
                    object, at: offset, from: UnsafeRawPointer(window),
                    count: count, replacing: true
                )

            default:
                result = disk.write(
                    object, at: offset, from: UnsafeRawPointer(window), count: count
                )
        }

        _ = reply(message: FileOperation.answer(
            result.status,
            value: UInt32(truncatingIfNeeded: result.bytes)
        ))
    }


    // MARK: - Clients

    private mutating func attach(_ request: inout ReceivedMessage) {

        let badge = request.identity
        guard badge != 0, let granted = request.grantedCap else { return }

        // The size comes from the kernel, not from the message. A client saying
        // four pages while granting one used to leave this process writing a
        // reply into three pages it does not have, which is a page fault at a
        // moment the client picked. The word in the request is not read at all
        // any more.
        let pages = shmPages(handle: granted)
        guard ShmAttachment.accepts(pages: pages, atMost: Self.maximumPages) else { return }

        // A client that is already here keeps its slot, and lets go of nothing
        // until the new attachment is installed.
        let existing = slot(for: badge)

        // Before refusing, ask which of the eight are still there: the ninth
        // client used to be turned away on a dead one's behalf.
        if existing == nil, freeSlot() == nil { sweepDeadClients() }

        // No room. The client learns this as a `status` that answers nothing,
        // which is true but says nothing about why, so the one process that
        // knows says it out loud. Refusing the ninth client is a decision this
        // table's fixed size makes; making it silently is not.
        guard let slot = existing ?? freeSlot() else {
            if !Self.saidClientsAreFull {
                Self.saidClientsAreFull = true
                print("[ FS    ] eight clients already attached, this one is refused")
            }
            return
        }

        // Minted before anything is mapped, so the one step that cannot be
        // undone happens after every step that can fail.
        guard let epoch = attachments[slot].nextEpoch() else { return }

        let address = shmMap(handle: granted)
        guard UnsafeMutableRawPointer(bitPattern: UInt(address)) != nil else { return }

        let extent = UInt64(pages) * Self.pageSize

        guard let owned = request.takeGrant() else {
            _ = munmap(addr: address, size: extent)
            return
        }

        // One store, and the old attachment comes back out of it.
        let letGo = attachments[slot].install(ShmAttachment(
            identity: badge,
            epoch   : epoch,
            address : address,
            extent  : extent,
            grant   : owned
        ))

        // Afterwards, and only afterwards. Attaching again is starting again, so
        // what the old session was holding goes with it.
        if let letGo {
            leases.forget(everythingHeldBy: letGo.identity)
            surrender(letGo)
        }
    }


    // MARK: - Claims

    /// The incarnation an object is at, or `nil` when there is no object there.
    ///
    /// A claim names a *thing*, and a slot number is not one: remove the file at
    /// slot twelve and the next `create` may be handed slot twelve, at which
    /// point a claim recorded as "twelve" would be holding a file nobody claimed.
    /// The same count that makes a capability name a thing makes a claim name
    /// one. See `FSObject.generation`.
    private mutating func generation(of object: UInt32) -> UInt32? {
        guard let record = disk.object(object), record.kind != .free else { return nil }

        return record.generation
    }


    /// Claims `object` for `badge`, or says who has it.
    private mutating func claim(
        _ object   : UInt32,
          for badge: UInt32,
          root     : UInt32
    ) -> FSStatus {

        guard disk.contains(object, within: root),
              let age = generation(of: object)
        else { return .notFound }

        if leases.claim(object, generation: age, for: badge) { return .ok }

        // Full, or held by somebody else. Anything whose object has moved on
        // since is let go of before giving up, which is the only cleanup this
        // table gets that does not need the holder to come back.
        forgetStaleClaims()

        if leases.claim(object, generation: age, for: badge) { return .ok }

        // `.busy` either way, and the two reasons for it are worth telling
        // apart. A table with no room is this server's problem and looks exactly
        // like contention from outside, so it says so once rather than letting a
        // fixed size fail quietly for the rest of the boot.
        if leases.isFull, !Self.saidLeasesAreFull {
            Self.saidLeasesAreFull = true
            print("[ FS    ] every claim slot is taken, claims are being refused")
        }

        return .busy
    }

    /// Said once. A saturated table refuses on every request after the first,
    /// and a console that says so every time is a console nobody can read.
    private nonisolated(unsafe) static var saidLeasesAreFull = false
    private nonisolated(unsafe) static var saidClientsAreFull = false


    /// Lets go of a claim, if this caller is the one holding it.
    private mutating func release(
        _ object    : UInt32,
          from badge: UInt32
    ) {
        leases.release(object, from: badge)
    }


    /// Forgets every claim whose holder is gone, or whose object is gone or has
    /// been handed on since.
    private mutating func forgetStaleClaims() {

        sweepDeadClients()

        for index in 0..<FSLeases.capacity {
            guard let entry = leases.entry(at: index) else { continue }
            guard generation(of: entry.object) != entry.age else { continue }

            leases.forget(at: index)
        }
    }


    /// Lets go of every slot whose client is no longer running.
    ///
    /// The kernel does not report a death, so this asks. It can ask because an
    /// identity is never reused: a badge naming nothing that runs names nothing
    /// at all, and everything held under it - the window, the granted capability,
    /// every claim - is held for nobody.
    ///
    /// Only reached where the leftovers of a dead client are about to be somebody
    /// else's refusal, which is why a syscall per slot is affordable: a full
    /// table, or a claim standing in a live client's way.
    private mutating func sweepDeadClients() {
        for index in 0..<Self.capacity {
            guard let held = attachments[index].current,
                  !identityAlive(held.identity) else { continue }

            release(slot: index)
        }
    }


    /// Whether `badge` may change `object`.
    ///
    /// The refusal is the interesting half. A claim whose holder has died refuses
    /// everybody for ever, and this is the path where that is felt: the holder is
    /// not coming back to call `unlock`, and nothing else on a write goes near
    /// the claim table. So a no is asked twice, with a sweep in between.
    private mutating func mayChange(
        _ object: UInt32,
        _ badge : UInt32
    ) -> Bool {

        let age = generation(of: object)

        if leases.mayChange(object, generation: age, by: badge) { return true }

        forgetStaleClaims()

        return leases.mayChange(object, generation: age, by: badge)
    }


    /// Whether `badge` may change every one of the objects an operation touches.
    ///
    /// No ordering, and none is wanted: a claim here is a *refusal* and never a
    /// wait, so there is no lock to acquire in the wrong order and nothing that
    /// can be held while asking for a second. Asking about three objects in any
    /// order gives the same answer. Ordering would matter the moment a claim
    /// started blocking, and that is the moment to add it.
    private mutating func mayChangeAll(
        _ first: UInt32,
        _ second: UInt32,
        _ third: UInt32? = nil,
        by badge: UInt32
    ) -> Bool {

        guard mayChange(first, badge), mayChange(second, badge) else { return false }
        guard let third else { return true }

        return mayChange(third, badge)
    }


    private func slot(for badge: UInt32) -> Int? {
        for index in 0..<Self.capacity where attachments[index].held(by: badge) {
            return index
        }
        return nil
    }

    private func freeSlot() -> Int? {
        for index in 0..<Self.capacity where attachments[index].current == nil {
            return index
        }
        return nil
    }

    private mutating func release(slot: Int) {

        guard let held = attachments[slot].take() else { return }

        // A client that goes away lets go of everything it was holding. A claim
        // that outlived its holder would be a file nobody can ever write again.
        leases.forget(everythingHeldBy: held.identity)

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


/// A byte as itself when it can be read, and a dot when it cannot.
private func readable(_ byte: UInt8) -> UInt8 {
    (byte >= 0x20 && byte < 0x7F) ? byte : UInt8(ascii: ".")
}
