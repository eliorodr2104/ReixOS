//
//  FileSystemClient.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// The file system, from the outside.
///
/// One page is shared with the server at attach time and everything travels
/// through it: names on the way in, bytes and listings on the way out. A
/// request is a message of four numbers, and no request costs a copy that was
/// not going to happen anyway.
public struct FileSystemClient {

    /// Four pages, which is what makes one read worth pipelining.
    ///
    /// It was one, so the longest transfer was a page: at most two blocks, and
    /// two is not enough to overlap anything. Four pages is up to five blocks in
    /// one request, which is where the file system's read loop can keep the disk
    /// busy instead of waiting for each block in turn.
    public static let windowPages: UInt64 = 4
    private static let pageSize: UInt64 = 4096

    /// The most bytes one call may move, which is the window.
    public static var maximumTransfer: UInt64 { windowPages * pageSize }

    public let endpoint: UInt32
    private let window : UnsafeMutableRawPointer

    /// The object this client is rooted at.
    ///
    /// Not chosen and not asked for: it is whatever the capability used to
    /// attach says it is, and the server tells the client on the way in. A
    /// process cannot widen it, because widening would mean re-badging a
    /// capability and the kernel will not badge one twice.
    public let root: UInt32

    /// What this client's own root is called, which is the first segment of any
    /// path written from it. For the machine's container that is the machine's
    /// name; for anything else it is the name the folder above knows it by.
    public let rootName: InlineArray<24, UInt8>
    public let rootNameLength: Int


    public init?(fileSystem endpoint: UInt32) {

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
            message    : FileOperation.attaching(pages: UInt32(Self.windowPages)),
            grant      : shared.handle,
            grantRights: [.read, .write]
        )

        // A capability naming no live root answers nothing here, so a process
        // that was never given one cannot attach at all.  A direct file or
        // folder root is deliberately valid: it gets a full status reply with
        // zero delegable room. `ask` is not available yet: `self` is half
        // built, so this one is spelled out.
        guard case .success(let answer) = call(
            handle : endpoint,
            message: FileOperation.status.transfer(object: 0, offset: 0, count: 0)
        ),
        FileOperation.isAttachAcknowledgement(answer.message)
        else { giveUp(); return nil }

        self.root = answer.message.words[3]

        var name   = InlineArray<24, UInt8>(repeating: 0)
        var length = 0

        let letters = window.assumingMemoryBound(to: UInt8.self)
        while length < 24, letters[length] != 0 {
            name[length] = letters[length]
            length += 1
        }

        self.rootName       = name
        self.rootNameLength = length
    }


    /// One request, and the reply if there really was one that answers it.
    ///
    /// `nil` for two different things that a caller treats the same way: the
    /// exchange did not happen, or what came back is not shaped like an answer
    /// to what was asked. Every caller turns that into its own "no answer"
    /// status *explicitly*, which is the point - a transport failure is not a
    /// value in this protocol's status enum, and deriving one from the other is
    /// how a dead file system came to look like an ordinary refusal.
    ///
    /// Two shapes answer any request, and both are accepted because the protocol
    /// really does have two. There is the reply the operation carries when it
    /// worked, named by `label` and `words` wide; and there is a plain status,
    /// which is what every refusal looks like - a server that could not do the
    /// thing has none of the thing to describe.
    ///
    /// Anything else is not an answer to this request. That catches a reply built
    /// with the wrong constructor, which is a server bug rather than anything an
    /// attacker reaches, and it catches a reply too short for the words about to
    /// be read out of it - reading past what the server filled in is reading
    /// whatever was in the frame.
    private func ask(
        _ message: Message,
        answeredBy label: FileOperation,
        words: UInt8 = 1
    ) -> ReceivedMessage? {

        guard case .success(let answer) = call(handle: endpoint, message: message) else {
            return nil
        }

        let tag = answer.message.tag

        if tag.label == label.rawValue {
            return tag.length >= words ? answer : nil
        }

        // A refusal. One word, and the caller reads no further than it.
        if tag.label == FileOperation.status.rawValue {
            return tag.length >= 1 ? answer : nil
        }

        return nil
    }


    /// Whether this client's root is the one `text` names.
    public func rootIsNamed(_ text: UnsafeRawPointer, length: Int) -> Bool {

        guard length == rootNameLength else { return false }

        let bytes = text.assumingMemoryBound(to: UInt8.self)
        for index in 0..<length where rootName[index] != bytes[index] { return false }

        return true
    }


    /// The room left in this client's own container, and whether the disk came
    /// back from an unclean shutdown.
    ///
    /// Blocks left in the container, not blocks left on the disk. A process
    /// inside a container has no business knowing how full the machine is, and
    /// no use for the number either: it cannot have any of it. A client rooted
    /// directly at a file or folder likewise receives zero: it has no room it
    /// can delegate.
    public func status() -> (
        status: FSStatus, freeBlocks: UInt32, dirty: Bool, quarantined: Bool
    ) {
        guard let answer = ask(
            FileOperation.status.transfer(object: 0, offset: 0, count: 0),
            answeredBy: .status,
            words    : 4
        ) else { return (.unreachable, 0, false, false) }

        return (
            FileOperation.status(of: answer.message),
            answer.message.words[1],
            answer.message.words[2] & 1 != 0,
            answer.message.words[2] & 2 != 0
        )
    }


    // MARK: - Containers

    /// Makes a container inside `folder`, with `room` blocks out of this
    /// client's own.
    public func createContainer(
        _ name: UnsafeRawPointer,
        length: Int,
        room  : UInt32,
        in folder: UInt32? = nil
    ) -> (status: FSStatus, file: FSFile?) {
        request(.createContainer, name, length: length, in: folder, kind: .container, room: room)
    }


    /// Asks for a capability naming `object`, to hand to somebody else.
    ///
    /// The object may be a container, a folder or a single file, and this is
    /// how a piece of one container reaches another: the holder asks for a
    /// capability naming exactly that piece and passes it on. What comes back
    /// is bound to that object and nothing else, and `readOnly` makes it a
    /// thing the receiver may look at and not touch.
    ///
    /// A read-only capability can only bind read-only ones. A share never grows
    /// as it travels.
    public func bind(_ object: UInt32, rights: FSRights = .everything) -> UInt32? {

        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = object

        // What is asked for. What comes back is this and no more, cut down to
        // what this client itself holds: the server intersects, so asking for
        // everything is asking for "as much as I have" rather than for more.
        words[1] = rights.rawValue

        guard var answer = ask(
            Message(tag: MessageTag(FileOperation.bind, length: 2), words: words),
            answeredBy: .status,
            words    : 2
        ) else { return nil }

        guard FileOperation.status(of: answer.message) == .ok else {
            if let stray = answer.takeGrant() { _ = capDrop(stray) }
            return nil
        }

        return answer.takeGrant()
    }


    /// The path from this client's own root down to `object`, written into
    /// `destination`. Answers how long it is, or zero when there is no path
    /// because the object is not somewhere this client can reach.
    public func pathResult(
        of object: UInt32,
        into destination: UnsafeMutableRawPointer,
        capacity: Int
    ) -> (status: FSStatus, length: Int) {

        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = object

        guard let answer = ask(
            Message(tag: MessageTag(FileOperation.path, length: 1), words: words),
            answeredBy: .status,
            words    : 2
        ) else { return (.unreachable, 0) }

        let status = FileOperation.status(of: answer.message)
        guard status == .ok else { return (status, 0) }

        let length = Int(answer.message.words[1])
        guard length > 0, length <= capacity else { return (.bufferTooSmall, 0) }

        destination.copyMemory(from: window, byteCount: length)

        return (.ok, length)
    }


    public func path(
        of object: UInt32,
        into destination: UnsafeMutableRawPointer,
        capacity: Int
    ) -> Int {
        pathResult(of: object, into: destination, capacity: capacity).length
    }


    /// Moves `blocks` of this client's room into a container directly inside it.
    public func grantRoom(_ blocks: UInt32, to container: UInt32) -> FSStatus {

        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = container
        words[1] = blocks

        guard let answer = ask(
            Message(tag: MessageTag(FileOperation.grantRoom, length: 2), words: words),
            answeredBy: .status
        ) else { return .unreachable }

        return FileOperation.status(of: answer.message)
    }


    // MARK: - Names

    public func open(_ name: UnsafeRawPointer, length: Int, in folder: UInt32? = nil)
    -> (status: FSStatus, file: FSFile?) {
        request(.open, name, length: length, in: folder, kind: .free)
    }

    public func create(
        _ name: UnsafeRawPointer,
        length: Int,
        kind  : FSKind = .file,
        in folder: UInt32? = nil
    ) -> (status: FSStatus, file: FSFile?) {
        request(.create, name, length: length, in: folder, kind: kind)
    }

    public func remove(_ name: UnsafeRawPointer, length: Int, from folder: UInt32? = nil)
    -> FSStatus {
        request(.remove, name, length: length, in: folder, kind: .free).status
    }


    private func request(
        _ operation: FileOperation,
        _ name: UnsafeRawPointer,
        length: Int,
        in folder: UInt32?,
        kind  : FSKind,
        room  : UInt32 = 0
    ) -> (status: FSStatus, file: FSFile?) {

        guard length > 0, UInt64(length) <= Self.maximumTransfer else { return (.badName, nil) }

        window.copyMemory(from: name, byteCount: length)

        // A removal answers a plain status; an open or a create answers the
        // thing it found or made, which is a different reply and says so in its
        // label.
        guard let answer = ask(
            operation.named(
                folder: folder ?? root,
                length: UInt32(length),
                kind  : kind,
                room  : room
            ),
            answeredBy: operation == .remove ? .status : .open,
            words    : operation == .remove ? 1 : 4
        ) else { return (.unreachable, nil) }

        let status = FileOperation.status(of: answer.message)
        guard status == .ok else { return (status, nil) }

        // A removal answers a plain status and has nothing to describe. Reading
        // an object out of that reply would be reading two words it never wrote.
        guard answer.message.tag.label == FileOperation.open.rawValue else {
            return (.ok, nil)
        }

        let described = FileOperation.described(answer.message)

        return (.ok, FSFile(
            object: described.object,
            kind  : described.kind,
            size  : described.size
        ))
    }


    /// As many of a folder's names as fit in `capacity` entries, written into
    /// `destination` from `cursor` on.
    ///
    /// One call for a batch of names where it used to be one call per name, and
    /// the round trips were the cost worth removing: every one of them parked the
    /// caller. The cursor comes back in the answer and goes into the next call,
    /// so a folder of any size is one pass over it.
    ///
    /// What comes back says how it went, how many names were written, and
    /// whether the folder ends here - three separate facts, because a batch can
    /// be full and be the last one, and a batch can be empty because the disk
    /// stopped answering. `step` is the whole rule for what to do next.
    public func listBatch(
        _ folder: UInt32? = nil,
        from cursor: UInt32,
        into destination: UnsafeMutableRawPointer,
        capacity: Int
    ) -> FSListBatchResult {

        let fits = min(
            min(capacity, Int(Self.maximumTransfer) / FSListEntry.width),
            FSListEntry.batchLimit
        )

        // Room for not one entry is refused here rather than asked about: the
        // same answer the server gives when a request will not fit its window.
        guard fits > 0 else {
            return FSListBatchResult(status: .noSpace, count: 0, next: cursor, eof: false)
        }

        guard let answer = ask(
            FileOperation.listing(
                folder  : folder ?? root,
                from    : cursor,
                capacity: UInt32(fits)
            ),
            answeredBy: .list,
            words    : 4
        ) else {
            return FSListBatchResult(status: .unreachable, count: 0, next: cursor, eof: false)
        }

        // A plain status reply means the request was refused before any name was
        // looked at, and it is four words shorter than a listing: reading a count
        // out of it would be reading a word the server never wrote.
        guard answer.message.tag.label == FileOperation.list.rawValue,
              answer.message.tag.length >= 4
        else {
            return FSListBatchResult(
                status: FileOperation.status(of: answer.message),
                count : 0,
                next  : cursor,
                eof   : false
            )
        }

        let status = FileOperation.status(of: answer.message)
        let count  = Int(FileOperation.listedCount(answer.message))

        guard count <= fits else {
            return FSListBatchResult(status: .unreachable, count: 0, next: cursor, eof: false)
        }

        if count > 0 {
            destination.copyMemory(
                from     : UnsafeRawPointer(window),
                byteCount: count * FSListEntry.width
            )
        }

        return FSListBatchResult(
            status: status,
            count : count,
            next  : FileOperation.listedNext(answer.message),
            eof   : FileOperation.listedEnd(answer.message)
        )
    }


    // MARK: - Bytes

    /// Reads up to `count` bytes. A short answer means the file ended.
    public func read(
        _ object: UInt32,
        at offset: UInt64,
        into destination: UnsafeMutableRawPointer,
        count: UInt64
    ) -> (status: FSStatus, bytes: UInt64) {

        let wanted = count > Self.maximumTransfer ? Self.maximumTransfer : count

        guard let answer = ask(
            FileOperation.read.transfer(object: object, offset: offset, count: UInt32(wanted)),
            answeredBy: .status,
            words    : 2
        ) else { return (.unreachable, 0) }

        let status = FileOperation.status(of: answer.message)
        guard status == .ok else { return (status, 0) }

        let moved = UInt64(answer.message.words[1])
        if moved > 0 { destination.copyMemory(from: window, byteCount: Int(moved)) }

        return (.ok, moved)
    }


    /// Writes `count` bytes, growing the object if it has to and keeping
    /// whatever was past the end.
    public func write(
        _ object: UInt32,
        at offset: UInt64,
        from source: UnsafeRawPointer,
        count: UInt64
    ) -> (status: FSStatus, bytes: UInt64) {
        put(.write, object, at: offset, from: source, count: count)
    }


    /// Makes `count` bytes the object's whole contents from `offset` on:
    /// anything past the last byte written is dropped.
    ///
    /// One request, so nobody can see the file half replaced.
    public func replace(
        _ object: UInt32,
        at offset: UInt64 = 0,
        from source: UnsafeRawPointer,
        count: UInt64
    ) -> (status: FSStatus, bytes: UInt64) {
        put(.replace, object, at: offset, from: source, count: count)
    }


    private func put(
        _ operation: FileOperation,
        _ object: UInt32,
        at offset: UInt64,
        from source: UnsafeRawPointer,
        count: UInt64
    ) -> (status: FSStatus, bytes: UInt64) {

        let wanted = count > Self.maximumTransfer ? Self.maximumTransfer : count
        guard wanted > 0 else { return (.ok, 0) }

        window.copyMemory(from: source, byteCount: Int(wanted))

        guard let answer = ask(
            operation.transfer(object: object, offset: offset, count: UInt32(wanted)),
            answeredBy: .status,
            words    : 2
        ) else { return (.unreachable, 0) }

        let status = FileOperation.status(of: answer.message)
        guard status == .ok else { return (status, 0) }

        return (.ok, UInt64(answer.message.words[1]))
    }


    // MARK: - Keeping the disk in order

    /// Puts a scattered object back into one run of blocks, when the disk has
    /// one to spare.
    ///
    /// What stops `tooFragmented` being a dead end: a file that has run out of
    /// extents has not run out of disk, it has run out of places to remember
    /// where its pieces are.
    public func compact(_ object: UInt32) -> FSStatus {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = object

        guard let answer = ask(
            Message(tag: MessageTag(FileOperation.compact, length: 1), words: words),
            answeredBy: .status
        ) else { return .unreachable }

        return FileOperation.status(of: answer.message)
    }


    /// Claims `object`, so that nobody else may change it until this client
    /// lets go or goes away.
    ///
    /// For a write that takes more than one request. A single write is already
    /// indivisible; a file replaced in four calls is not, and this is how that
    /// is said out loud.
    public func lock(_ object: UInt32) -> FSStatus {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = object

        guard let answer = ask(
            Message(tag: MessageTag(FileOperation.lock, length: 1), words: words),
            answeredBy: .status
        ) else { return .unreachable }

        return FileOperation.status(of: answer.message)
    }


    /// Lets go of a claim.
    @discardableResult
    public func unlock(_ object: UInt32) -> FSStatus {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = object

        guard let answer = ask(
            Message(tag: MessageTag(FileOperation.unlock, length: 1), words: words),
            answeredBy: .status
        ) else { return .unreachable }

        return FileOperation.status(of: answer.message)
    }


    /// Puts a whole run of bytes into an object, however many requests that
    /// takes, with nobody else able to change it in between.
    ///
    /// The one thing a client could not do for itself: the loop is here because
    /// the claim has to wrap the whole loop, and a caller writing the loop
    /// itself would have to remember to.
    public func replaceAll(
        _ object: UInt32,
        from source: UnsafeRawPointer,
        count: UInt64
    ) -> (status: FSStatus, bytes: UInt64) {

        let claimed = lock(object)
        guard claimed == .ok else { return (claimed, 0) }

        defer { unlock(object) }

        var moved = UInt64(0)
        var first = true

        while moved < count {
            let chunk = min(Self.maximumTransfer, count - moved)

            // The first request is the one that shortens: it says what the file
            // now is, and the rest add to it.
            let result = first
                ? replace(object, at: 0, from: source, count: chunk)
                : write(object, at: moved, from: source.advanced(by: Int(moved)), count: chunk)

            guard result.status == .ok, result.bytes > 0 else {
                return (result.status == .ok ? .deviceFailed : result.status, moved)
            }

            moved += result.bytes
            first  = false
        }

        return (.ok, moved)
    }


    /// The folder above `object`, or `object` itself when it is this client's
    /// own root: going up stops at the edge of what it holds.
    public func up(from object: UInt32) -> UInt32? {

        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = object

        guard let answer = ask(
            Message(tag: MessageTag(FileOperation.up, length: 1), words: words),
            answeredBy: .status,
            words    : 2
        ) else { return nil }

        guard FileOperation.status(of: answer.message) == .ok else { return nil }

        return answer.message.words[1]
    }


    /// What `object` is: kind, size, and when it was made and last changed.
    public func info(of object: UInt32) -> FSInfo? {

        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = object

        guard let answer = ask(
            Message(tag: MessageTag(FileOperation.info, length: 1), words: words),
            answeredBy: .status,
            words    : 2
        ) else { return nil }

        guard FileOperation.status(of: answer.message) == .ok else { return nil }

        return FSInfo(reading: UnsafeRawPointer(window))
    }


    /// Gives something a new name, a new folder, or both, in one request.
    public func relocate(
        _ name: UnsafeRawPointer,
        length: Int,
        from folder: UInt32,
        to target: UInt32,
        as newName: UnsafeRawPointer,
        length newLength: Int
    ) -> FSStatus {

        guard length > 0, newLength > 0,
              UInt64(length + newLength) <= Self.maximumTransfer
        else { return .badName }

        window.copyMemory(from: name, byteCount: length)
        window.advanced(by: length).copyMemory(from: newName, byteCount: newLength)

        guard let answer = ask(
            FileOperation.relocating(
                from  : folder,
                length: UInt32(length),
                to    : target,
                length: UInt32(newLength)
            ),
            answeredBy: .status
        ) else { return .unreachable }

        return FileOperation.status(of: answer.message)
    }


    /// Renames the machine. Only a client holding the machine may.
    public func nameMachine(_ text: UnsafeRawPointer, length: Int) -> FSStatus {

        guard length > 0, UInt64(length) <= Self.maximumTransfer else { return .badName }

        window.copyMemory(from: text, byteCount: length)

        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = UInt32(length)

        guard let answer = ask(
            Message(tag: MessageTag(FileOperation.nameMachine, length: 1), words: words),
            answeredBy: .status
        ) else { return .unreachable }

        return FileOperation.status(of: answer.message)
    }


    /// Walks the whole volume and answers whether it is still safe to serve.
    public func scrub() -> FSStatus {

        guard let answer = ask(
            Message(
                tag  : MessageTag(FileOperation.scrub, length: 0),
                words: InlineArray<4, UInt32>(repeating: 0)
            ),
            answeredBy: .status
        ) else { return .unreachable }

        return FileOperation.status(of: answer.message)
    }


    /// Marks the disk clean. Nothing is served afterwards, so this is the last
    /// thing anybody says to it.
    public func unmount() -> FSStatus {

        guard let answer = ask(
            Message(
                tag  : MessageTag(FileOperation.unmount, length: 0),
                words: InlineArray<4, UInt32>(repeating: 0)
            ),
            answeredBy: .status
        ) else { return .unreachable }

        return FileOperation.status(of: answer.message)
    }
}
