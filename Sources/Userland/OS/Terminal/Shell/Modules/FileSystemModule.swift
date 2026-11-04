//
//  FileSystemModule.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

/// Names, folders, containers, and where the shell is standing.
///
/// The module that manipulates the shell's own data as well as the disk's:
/// `move` changes where the session is and every other verb reads it. That is
/// why the session is a type handed in and handed back rather than a pile of
/// globals - a module changing the shell has to be something you can see
/// happening in a signature.
public enum FileSystemModule: ShellModule {

    /// The commands this module declares, which are not the same list as the
    /// verbs its handler answers: `changeDir` and `move` are spelled `move`
    /// and `rename` inside, and two of them share one handler.
    enum Declared: UInt16 {
        case list, currentDirectory, changeDir, move, free, info, read, write
        case createDirectory, createFile, createContainer, remove, name
        case unmount, compact, scrub, exists
    }

    public static var namespace: ShellNamespaceDescriptor {
        ShellNamespaceDescriptor("FileManager", capability: .container, summary: "this shell's container")
    }

    public static var commandCount: Int { Int(Declared.exists.rawValue) + 1 }

    public static func command(at index: Int) -> ShellCommandDescriptor? {
        guard let declared = Declared(rawValue: UInt16(index)) else { return nil }
        switch declared {
            case .list:
                return descriptor(declared, "list", TypedShellSignature(namespace: "FileManager", name: "list", result: .sequence),
                                  schema: .entries, summary: "what is here")
            case .currentDirectory:
                return descriptor(declared, "where", TypedShellSignature(namespace: "FileManager", name: "currentDirectory", effect: .session),
                                  summary: "say where this shell is standing")
            case .changeDir:
                return descriptor(declared, "move", TypedShellSignature(namespace: "FileManager", name: "changeDir", TypedShellParameter("at", subject: .path, pathTarget: .place), effect: .session),
                                  summary: "change this session's directory")
            case .move:
                return descriptor(declared, "rename", TypedShellSignature(namespace: "FileManager", name: "move", TypedShellParameter("from", subject: .path), TypedShellParameter("to", subject: .path)),
                                  sensitive: true, summary: "rename it, or move it")
            case .free:
                return descriptor(declared, "free", TypedShellSignature(namespace: "FileManager", name: "free"),
                                  summary: "how much room is left")
            case .info:
                return descriptor(declared, "info", TypedShellSignature(namespace: "FileManager", name: "info", TypedShellParameter("at", subject: .path)),
                                  summary: "what something is, and when")
            case .read:
                return descriptor(declared, "read", TypedShellSignature(namespace: "FileManager", name: "read", TypedShellParameter("at", subject: .path, pathTarget: .file)),
                                  summary: "the first bytes of a file")
            case .write:
                return descriptor(declared, "write", TypedShellSignature(namespace: "FileManager", name: "write", TypedShellParameter("at", subject: .path), TypedShellParameter("text")),
                                  sensitive: true, summary: "replace what a file says")
            case .createDirectory:
                return descriptor(declared, "folder", TypedShellSignature(namespace: "FileManager", name: "createDirectory", TypedShellParameter("at", subject: .path)),
                                  summary: "make a folder")
            case .createFile:
                return descriptor(declared, "write", TypedShellSignature(namespace: "FileManager", name: "createFile", TypedShellParameter("at", subject: .path)),
                                  sensitive: true, summary: "make an empty file")
            case .createContainer:
                return descriptor(declared, "container", TypedShellSignature(namespace: "FileManager", name: "createContainer", TypedShellParameter("name"), TypedShellParameter("blocks")),
                                  sensitive: true, summary: "cut a container out of this one")
            case .remove:
                return descriptor(declared, "remove", TypedShellSignature(namespace: "FileManager", name: "remove", TypedShellParameter("at", subject: .path)),
                                  sensitive: true, summary: "take it away")
            case .name:
                return descriptor(declared, "name", TypedShellSignature(namespace: "FileManager", name: "name", TypedShellParameter("name")),
                                  sensitive: true, summary: "rename the machine")
            case .unmount:
                return descriptor(declared, "unmount", TypedShellSignature(namespace: "FileManager", name: "unmount"),
                                  sensitive: true, summary: "mark the disk clean before stopping")
            case .compact:
                return descriptor(declared, "compact", TypedShellSignature(namespace: "FileManager", name: "compact", TypedShellParameter("at", subject: .path, pathTarget: .file)),
                                  summary: "put a scattered file back in one piece")
            case .scrub:
                return descriptor(declared, "scrub", TypedShellSignature(namespace: "FileManager", name: "scrub"),
                                  summary: "read the whole disk and say what is wrong")
            case .exists:
                return descriptor(declared, "exists", TypedShellSignature(namespace: "FileManager", name: "exists", TypedShellParameter("at", subject: .path), result: .boolean),
                                  schema: .boolean, summary: "whether anything is there")
        }
    }

    /// Listing answers with the directory itself rather than with records.
    public static func value(
        for code  : UInt16,
          in session: inout ShellSession
    ) -> TypedShellInvocationResult? {
        guard Declared(rawValue: code) == .list else { return nil }
        return listValue(in: &session)
    }

    /// `createFile` is `write` with nothing to write, and an empty argument is
    /// the only way to say so.
    public static func fill(
        _ command: inout Command,
          for code: UInt16,
          at cursor: Int
    ) -> Bool {
        guard Declared(rawValue: code) == .createFile else { return true }
        guard command.argumentCount < command.arguments.count else { return false }
        command.arguments[command.argumentCount] = Span(start: cursor, count: 0)
        command.argumentCount += 1
        return true
    }

    /// Every path-taking command reaches this one live vocabulary. The
    /// signature decides whether files or places fit; command spellings never
    /// appear here, so a newly declared path parameter is completed at once.
    public static func complete(
        _ request: ShellModuleCompletionRequest,
          in session: inout ShellSession,
          into offered: inout ShellCompletionSet
    ) {
        guard request.parameter.subject == .path,
              let files = Files.attached(session.environment)
        else { return }
        if session.folder == 0 {
            session.container = files.root
            session.folder = files.root
        }
        completePath(request, in: &session, files: files, into: &offered)
    }

    private static func descriptor(
        _ declared : Declared,
        _ verb     : StaticString,
        _ signature: TypedShellSignature,
          sensitive: Bool = false,
          schema   : ShellTypeSchema = .none,
          summary  : StaticString
    ) -> ShellCommandDescriptor {
        ShellCommandDescriptor(
            code      : declared.rawValue,
            verb      : verb,
            signature : signature,
            capability: .container,
            sensitive : sensitive,
            schema    : schema,
            summary   : summary
        )
    }

    public static func handle(
        _ command   : Command,
          in session: inout ShellSession
    ) -> ShellOutcome {
        handleResult(command, in: &session).outcome
    }

    public static func handleResult(
        _ command   : Command,
          in session: inout ShellSession
    ) -> ShellCommandResult {
        FileSystemOutput.begin()
        let outcome = carry(command, in: &session)
        return ShellCommandResult(outcome: outcome, records: FileSystemOutput.take(), frame: FileSystemOutput.takeFrame())
    }

    private static func carry(
        _ command   : Command,
          in session: inout ShellSession
    ) -> ShellOutcome {

        guard let verb = Verb(command, session) else { return .notHandled }

        // Every verb of this module, counted in one place. Judged before the
        // disk is looked for, because a line with the wrong number of arguments
        // is wrong on a machine with no disk too.
        let signature = arity(of: verb)
        guard signature.accepts(command.argumentCount) else {
            FileSystemOutput.literal("  ")
            FileSystemOutput.literal(signature.usage)
            FileSystemOutput.literal("\n")
            return .handled
        }

        guard let files = Files.attached(session.environment) else {
            FileSystemOutput.literal("this shell was given no view of the disk\n")
            return .handled
        }

        // Where the shell is standing, the first time it is asked.
        //
        // Nought is not a handle - a handle is an object number plus one - so it
        // is the honest way to say "nowhere yet", and this is where it stops
        // being nowhere. It used to be nought and stay nought, and work anyway,
        // because nought was also the machine's own object number: the shell was
        // standing at the root by arithmetic rather than by being put there.
        if session.folder == 0 {
            session.container = files.root
            session.folder    = files.root
        }

        carry(verb, command, &session, files)
        return .handled
    }

    /// Supplies one bounded, eager directory materialization to the evaluator.
    /// The service is consumed through its real batch cursor, but records are
    /// retained locally before transforms run. Crossing the explicit budget is
    /// a typed failure; no batch or record is silently shortened.
    public static func listValue(in session: inout ShellSession) -> TypedShellInvocationResult {
        guard let files = Files.attached(session.environment) else {
            return .failure(FSStatus.notFound.rawValue)
        }
        if session.folder == 0 {
            session.container = files.root
            session.folder = files.root
        }
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: listBatchSize * FSListEntry.width) { room in
            let base     = UnsafeMutableRawPointer(room.baseAddress!)
            var sequence = ShellSequence()
            var cursor   = UInt32(0)
            while true {
                sequence.beginBatch()
                let batch    = files.listBatch(session.folder, from: cursor, into: base, capacity: listBatchSize)
                let found    : Int
                let finished : Bool
                switch batch.step {
                    case .more(let count): found = count; finished = false
                    case .end(let count): found = count; finished = true
                    case .stopped(_, let status): return .failure(status.rawValue)
                }
                for index in 0..<found {
                    let entry = FSListEntry(reading: base.advanced(by: index * FSListEntry.width))
                    let name  = entry.name.span.withUnsafeBufferPointer {
                        ShellText($0.baseAddress!, count: Int(entry.length))
                    }
                    guard let name else { return .failure(FSStatus.badName.rawValue) }
                    let object = ShellObject(kind: UInt16(entry.kind.rawValue), name: name, number0: UInt64(entry.reference))
                    if case .failure(.materializationLimit(let limit)) = sequence.append(object) {
                        return .materializationLimit(limit)
                    }
                }
                if finished { return .sequence(sequence) }
                cursor = batch.next
            }
        }
    }


    /// What each verb takes.
    ///
    /// A switch and not a table, so a verb added without a signature does not
    /// compile. The signatures themselves live in the language, where a host
    /// suite can hold them to the numbers they claim.
    private static func arity(of verb: Verb) -> Arity {
        switch verb {
            case .where_   : Verbs.fsWhere
            case .move     : Verbs.fsMove
            case .list     : Verbs.fsList
            case .free     : Verbs.fsFree
            case .info     : Verbs.fsInfo
            case .read     : Verbs.fsRead
            case .write    : Verbs.fsWrite
            case .folder   : Verbs.fsFolder
            case .container: Verbs.fsContainer
            case .rename   : Verbs.fsRename
            case .remove   : Verbs.fsRemove
            case .name     : Verbs.fsName
            case .unmount  : Verbs.fsUnmount
            case .compact  : Verbs.fsCompact
            case .scrub    : Verbs.fsScrub
            case .exists   : Verbs.fsExists
        }
    }


    /// Everything this module answers to.
    ///
    /// A closed list rather than a chain of comparisons, so that adding a verb
    /// is a case and forgetting to handle it is a compile error.
    private enum Verb {
        case where_, move, list, free, info, read, write
        case folder, container, rename, remove, name, unmount, compact, scrub, exists

        init?(
            _ command: Command,
            _ session: ShellSession
        ) {
            switch true {
                case session.spells(command.verb, "where")    : self = .where_
                case session.spells(command.verb, "move")     : self = .move
                case session.spells(command.verb, "list")     : self = .list
                case session.spells(command.verb, "free")     : self = .free
                case session.spells(command.verb, "info")     : self = .info
                case session.spells(command.verb, "read")     : self = .read
                case session.spells(command.verb, "write")    : self = .write
                case session.spells(command.verb, "folder")   : self = .folder
                case session.spells(command.verb, "container"): self = .container
                case session.spells(command.verb, "rename")   : self = .rename
                case session.spells(command.verb, "remove")   : self = .remove
                case session.spells(command.verb, "name")     : self = .name
                case session.spells(command.verb, "unmount")  : self = .unmount
                case session.spells(command.verb, "compact")  : self = .compact
                case session.spells(command.verb, "scrub")    : self = .scrub
                case session.spells(command.verb, "exists")   : self = .exists
                default: return nil
            }
        }
    }


    private static func carry(
        _ verb   : Verb,
        _ command: Command,
        _ session: inout ShellSession,
        _ files  : FileSystemClient
    ) {
        switch verb {
            case .where_:
                showPlace(files, session.folder)

            case .free:
                let state = files.status()
                FileSystemOutput.room(state)

            case .unmount:
                report(files.unmount())

            case .scrub:
                FileSystemOutput.literal("  reading the whole disk, this takes a moment\n")

                let outcome = files.scrub()
                guard let frame = outcome.frame else {
                    report(outcome.status)
                    return
                }
                FileSystemOutput.frame = frame

            case .name:
                guard let text = session.bytes(of: command.arguments[0]) else { invalidLine(); return }
                report(files.nameMachine(text.bytes, length: text.count))

            case .move:
                move(to: command.arguments[0], &session, files)

            case .list:
                guard let place = target(command, &session, files) else { return }
                listFiles(files, in: place.folder)

            case .rename:
                rename(command, &session, files)

            default:
                act(verb, command, &session, files)
        }
    }


    /// The verbs that name one thing and do something to it.
    private static func act(
        _ verb   : Verb,
        _ command: Command,
        _ session: inout ShellSession,
        _ files  : FileSystemClient
    ) {
        guard let found = locate(command.arguments[0], &session, files) else { return }

        guard found.leaf.count > 0 else {
            FileSystemOutput.literal("  that path names a place, not a thing in one\n")
            return
        }

        guard let leaf = session.bytes(of: found.leaf) else { invalidLine(); return }

        let name   = leaf.bytes
        let length = leaf.count
        let folder = found.place.folder

        switch verb {
            case .remove:
                report(files.remove(name, length: length, from: folder))

            case .read:
                readFile(files, name: name, length: length, in: folder)

            case .info:
                explain(files, name: name, length: length, in: folder)

            case .exists:
                // A name that is not there is an answer, not a failure: this
                // is the one verb whose whole point is asking.
                let opened = files.open(name, length: length, in: folder)
                FileSystemOutput.literal(opened.status == .ok ? "  yes\n" : "  no\n")

            case .compact:
                let opened = files.open(name, length: length, in: folder)

                guard opened.status == .ok, let file = opened.file else {
                    report(opened.status)
                    return
                }

                report(files.compact(file.object))

            case .folder:
                report(files.create(name, length: length, kind: .folder, in: folder).status)

            case .container:
                // The size is bounded here rather than truncated on the way in.
                // Truncating turned a size nobody can have into a small one they
                // did not ask for: four thousand million and one blocks quietly
                // became one.
                guard let room = decimal(command.arguments[1], session),
                      room <= UInt64(UInt32.max)
                else {
                    FileSystemOutput.literal("  ")
                    FileSystemOutput.literal(Verbs.fsContainer.usage)
                    FileSystemOutput.literal("\n")
                    return
                }

                report(files.createContainer(
                    name,
                    length: length,
                    room  : UInt32(room),
                    in    : folder
                ).status)

            default:
                guard let text = session.bytes(of: command.arguments[1]) else { invalidLine(); return }

                writeFile(
                    files, name: name, length: length, in: folder,
                    text: text.bytes, count: text.count
                )
        }
    }


    /// `fs.rename old new`: a new name, a new folder, or both.
    private static func rename(
        _ command: Command,
        _ session: inout ShellSession,
        _ files  : FileSystemClient
    ) {
        guard let from = locate(command.arguments[0], &session, files),
              let to   = locate(command.arguments[1], &session, files)
        else { return }

        guard from.leaf.count > 0, to.leaf.count > 0 else {
            FileSystemOutput.literal("  both sides have to name a thing, not a place\n")
            return
        }

        guard let old = session.bytes(of: from.leaf),
              let new = session.bytes(of: to.leaf)
        else { invalidLine(); return }

        report(files.relocate(
            old.bytes,
            length: old.count,
            from  : from.place.folder,
            to    : to.place.folder,
            as    : new.bytes,
            length: new.count
        ))
    }


    /// The place a path argument names, opening its last name when there is one.
    ///
    /// It used to take a `needsLeaf` that nothing read: the one caller passed
    /// false and the body never looked. A parameter naming a policy that does
    /// not exist is worse than no parameter, because the next reader believes it.
    private static func target(
        _ command: Command,
        _ session: inout ShellSession,
        _ files  : FileSystemClient
    ) -> Place? {

        guard command.argumentCount >= 1 else {
            return Place(container: session.container, folder: session.folder)
        }

        guard let found = locate(command.arguments[0], &session, files) else { return nil }

        return step(into: found, session, files)
    }
}

private func invalidLine() {
    FileSystemOutput.literal("  that is not part of the line this shell read\n")
}


/// Walks a written path and answers the folder it names.
///
/// Crossing a `::` is opening a name and finding a container behind it. `..` is
/// asking the file system what is above, which stops at the edge of what this
/// shell holds rather than failing there: there is nothing above it that it has
/// a name for.
private func resolve(
    _ parts  : PathParts,
    _ session: inout ShellSession,
    _ files  : FileSystemClient
) -> Place? {

    var here = parts.isRooted
        ? Place(container: files.root, folder: files.root)
        : Place(container: session.container, folder: session.folder)

    if parts.isRooted {
        guard let root = session.bytes(of: parts.root) else { invalidLine(); return nil }

        guard files.rootIsNamed(root.bytes, length: root.count) else {
            FileSystemOutput.literal("  no such place\n")
            return nil
        }
    }

    for index in 0..<parts.containerCount {
        let segment = parts.containers[index]

        guard let name = session.bytes(of: segment) else { invalidLine(); return nil }

        let opened = files.open(
            name.bytes,
            length: name.count,
            in    : here.container
        )

        guard opened.status == .ok, let found = opened.file, found.kind == .container else {
            report(opened.status == .ok ? .wrongKind : opened.status)
            return nil
        }

        here = Place(container: found.object, folder: found.object)
    }

    // Every folder but the last: the last one is what the verb acts on, and
    // whether it has to exist depends on the verb.
    for index in 0..<maxOf(parts.folderCount - 1, 0) {
        let segment = parts.folders[index]

        guard let stepped = walk(segment, from: here, session, files) else { return nil }
        here = stepped
    }

    return here
}


/// One step of a path: up, or into something.
private func walk(
    _ segment: Span,
    from here: Place,
    _ session: ShellSession,
    _ files  : FileSystemClient
) -> Place? {

    if session.spells(segment, "..") {
        guard let above = files.up(from: here.folder) else {
            report(.notFound)
            return nil
        }

        // The container only changes when the folder left is the container
        // itself, which is the moment the walk crosses a boundary upward.
        return Place(
            container: here.folder == here.container ? above : here.container,
            folder   : above
        )
    }

    if session.spells(segment, ".") { return here }

    guard let name = session.bytes(of: segment) else { invalidLine(); return nil }

    let opened = files.open(
        name.bytes,
        length: name.count,
        in    : here.folder
    )

    guard opened.status == .ok, let found = opened.file, found.kind != .file else {
        report(opened.status == .ok ? .wrongKind : opened.status)
        return nil
    }

    return Place(
        container: found.kind == .container ? found.object : here.container,
        folder   : found.object
    )
}


func maxOf(
    _ a: Int,
    _ b: Int
) -> Int { a > b ? a : b }


/// Takes a written path apart and walks it, saying why if it cannot.
private func locate(
    _ span   : Span,
    _ session: inout ShellSession,
    _ files  : FileSystemClient
) -> (place: Place, leaf: Span)? {

    guard let taken = session.path(span) else { return nil }

    switch taken {
        case .failure(let why):
            switch why {
                case .emptySegment: FileSystemOutput.literal("  a path may not have an empty piece in it\n")
                case .loneColon   : FileSystemOutput.literal("  crossing into a container is written ::\n")
                case .tooDeep     : FileSystemOutput.literal("  that path is deeper than this shell will follow\n")
                // Unreachable through `session.path`, which turns it into a nil
                // and its own message. Named rather than defaulted so that a new
                // failure has to be answered here too.
                case .notALine    : FileSystemOutput.literal("  that is not part of the line this shell read\n")
            }
            return nil

        case .success(let parts):
            guard let place = resolve(parts, &session, files) else { return nil }
            return (place, parts.leaf)
    }
}


/// Moves the shell to the place a path names.
private func move(
    to path: Span,
    _ session: inout ShellSession,
    _ files: FileSystemClient
) {
    guard let found = locate(path, &session, files) else { return }

    // A path ending in `..` has already gone up: its last piece is a step and
    // not a thing to open.
    let place: Place?

    if session.spells(found.leaf, "..") || session.spells(found.leaf, ".") {
        place = walk(found.leaf, from: found.place, session, files)
    } else {
        place = step(into: found, session, files)
    }

    guard let place else { return }

    session.container = place.container
    session.folder    = place.folder

    showPlace(files, session.folder)
}


/// Opens the last name of a resolved path and answers the place it leads to.
func step(
    into found: (place: Place, leaf: Span),
    _ session : ShellSession,
    _ files   : FileSystemClient
) -> Place? {

    guard found.leaf.count > 0 else { return found.place }

    guard let leaf = session.bytes(of: found.leaf) else { invalidLine(); return nil }

    let opened = files.open(
        leaf.bytes,
        length: leaf.count,
        in    : found.place.folder
    )

    guard opened.status == .ok, let target = opened.file else {
        report(opened.status)
        return nil
    }

    guard target.kind != .file else {
        FileSystemOutput.literal("  that is a file, not a place\n")
        return nil
    }

    return Place(
        container: target.kind == .container ? target.object : found.place.container,
        folder   : target.object
    )
}


/// Says where the shell is standing, in the syntax it would be written in.
///
/// The file system writes it, because it is the only one that can: walking back
/// up means reading the folder above each name, and the shell has no way to
/// look upward. What comes back begins at this shell's own root and never above
/// it.
private func showPlace(
    _ files : FileSystemClient,
    _ folder: UInt32
) {

    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 256) { buffer in
        let path = files.pathResult(
            of      : folder,
            into    : UnsafeMutableRawPointer(buffer.baseAddress!),
            capacity: 256
        )

        guard path.status == .ok, path.length > 0 else {
            if path.status == .ok {
                FileSystemOutput.literal("  nowhere this shell can name\n")
            } else {
                report(path.status)
            }
            return
        }
        var offset = 0
        while offset < path.length {
            let first     = offset == 0
            let remaining = path.length - offset
            let amount    = ShellTextChunking.amount(remaining: remaining, first: first)
            let last      = amount == remaining
            guard FileSystemOutput.records.appendFileSystemPath(
                buffer.baseAddress! + offset,
                count: amount,
                first: first,
                last: last
            ) else { break }
            offset += amount
        }
    }
}


/// How many names one request asks for.
///
/// Thirty-two entries is two kilobytes of the window, and a folder of thirty-two
/// names is one round trip where it used to be thirty-two. Bigger buys less and
/// less: the cost that mattered was per-call, not per-entry.
private let listBatchSize = 32

/// A completion remains interactive even when a hostile or damaged service
/// never reaches the end of a listing. The list itself still has top-K bounds;
/// this is the independent bound on service work per request.
private let completionEntryLimit = FSListEntry.batchLimit

private func completePath(
    _ request: ShellModuleCompletionRequest,
      in session: inout ShellSession,
      files: FileSystemClient,
      into offered: inout ShellCompletionSet
) {
    let whole = request.context.prefix
    guard let written = session.bytes(of: whole) else { return }

    // A quoted path lends only its contents to PathParser. When the quote is
    // still open, accepting a candidate closes it; a settled quoted value is
    // already complete and has no leaf at the cursor to extend.
    var path = whole
    var closing: StaticString = ""
    if written.count > 0, written.bytes[0] == 0x22 {
        if written.count > 1, written.bytes[written.count - 1] == 0x22 { return }
        path = Span(start: whole.start + 1, count: whole.count - 1)
        closing = "\""
    }
    guard let typed = session.bytes(of: path) else { return }

    var leafOffset = 0
    var baseCount  = 0
    var index      = 0
    while index < typed.count {
        switch typed.bytes[index] {
            case 0x2F:
                leafOffset = index + 1
                baseCount = index
            case 0x3A:
                guard index + 1 < typed.count, typed.bytes[index + 1] == 0x3A else { return }
                leafOffset = index + 2
                // A trailing `::` is meaningful to PathParser; keep it in the
                // place being resolved, unlike a trailing slash.
                baseCount = index + 2
                index += 1
            default:
                break
        }
        index += 1
    }

    let here: Place
    if leafOffset == 0 {
        here = Place(container: session.container, folder: session.folder)
    } else {
        let base = Span(start: path.start, count: baseCount)
        guard let resolved = completionPlace(base, session, files) else { return }
        here = resolved
    }

    let leaf = Span(
        start: path.start + leafOffset,
        count: typed.count - leafOffset
    )
    let prefix = typed.bytes.advanced(by: leafOffset)
    let prefixCount = typed.count - leafOffset

    if request.parameter.pathTarget == .place, files.up(from: here.folder) != nil {
        let parent : StaticString = ".."
        offerPath(
            parent.utf8Start,
            count: 2,
            kind: .folder,
            prefix: prefix,
            prefixCount: prefixCount,
            replacement: leaf,
            target: request.parameter.pathTarget,
            suffix: closing,
            into: &offered
        )
    }

    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: listBatchSize * FSListEntry.width) { room in
        let base = UnsafeMutableRawPointer(room.baseAddress!)
        var cursor = UInt32(0)
        var seen   = 0
        while seen < completionEntryLimit {
            let capacity = min(listBatchSize, completionEntryLimit - seen)
            let batch = files.listBatch(here.folder, from: cursor, into: base, capacity: capacity)
            let found: Int
            let finished: Bool
            switch batch.step {
                case .more(let count): found = count; finished = false
                case .end(let count): found = count; finished = true
                case .stopped(let count, _): found = count; finished = true
            }
            for offset in 0..<found {
                let entry = FSListEntry(reading: base.advanced(by: offset * FSListEntry.width))
                entry.name.span.withUnsafeBufferPointer { name in
                    offerPath(
                        name.baseAddress!,
                        count: Int(entry.length),
                        kind: entry.kind,
                        prefix: prefix,
                        prefixCount: prefixCount,
                        replacement: leaf,
                        target: request.parameter.pathTarget,
                        suffix: closing,
                        into: &offered
                    )
                }
            }
            seen += found
            if finished || found == 0 || batch.next == cursor { return }
            cursor = batch.next
        }
        offered.markIncomplete()
    }
}

/// Resolves only the already-written parent of a candidate, without emitting a
/// diagnostic or changing the shell's place.
private func completionPlace(
    _ span   : Span,
    _ session: ShellSession,
    _ files  : FileSystemClient
) -> Place? {
    guard let parsed = session.path(span), case .success(let parts) = parsed else { return nil }
    var here = parts.isRooted
        ? Place(container: files.root, folder: files.root)
        : Place(container: session.container, folder: session.folder)

    if parts.isRooted {
        guard let root = session.bytes(of: parts.root),
              files.rootIsNamed(root.bytes, length: root.count)
        else { return nil }
    }
    for index in 0..<parts.containerCount {
        guard let name = session.bytes(of: parts.containers[index]) else { return nil }
        let opened = files.open(name.bytes, length: name.count, in: here.container)
        guard opened.status == .ok, let found = opened.file, found.kind == .container else { return nil }
        here = Place(container: found.object, folder: found.object)
    }
    for index in 0..<parts.folderCount {
        guard let next = completionStep(parts.folders[index], from: here, session, files) else { return nil }
        here = next
    }
    return here
}

private func completionStep(
    _ segment: Span,
    from here: Place,
    _ session: ShellSession,
    _ files  : FileSystemClient
) -> Place? {
    if session.spells(segment, ".") { return here }
    if session.spells(segment, "..") {
        guard let above = files.up(from: here.folder) else { return nil }
        return Place(
            container: here.folder == here.container ? above : here.container,
            folder   : above
        )
    }
    guard let name = session.bytes(of: segment) else { return nil }
    let opened = files.open(name.bytes, length: name.count, in: here.folder)
    guard opened.status == .ok, let found = opened.file, found.kind != .file else { return nil }
    return Place(
        container: found.kind == .container ? found.object : here.container,
        folder   : found.object
    )
}

private func offerPath(
    _ name: UnsafePointer<UInt8>,
      count: Int,
      kind: FSKind,
      prefix: UnsafePointer<UInt8>,
      prefixCount: Int,
      replacement: Span,
      target: ShellPathTarget,
      suffix: StaticString,
      into offered: inout ShellCompletionSet
) {
    guard count > 0, count <= ShellCompletion.nameCapacity,
          pathTarget(target, accepts: kind), prefixCount <= count
    else { return }
    for index in 0..<prefixCount where prefix[index] != name[index] { return }
    guard let candidate = ShellCompletion(
        kind   : .path,
        bytes  : name,
        count  : count,
        suffix : suffix,
        detail : pathKind(kind),
        summary: "reachable from the current place",
        rank   : 0,
        replacement: replacement
    ) else { return }
    offered.insert(candidate)
}

private func pathTarget(_ target: ShellPathTarget, accepts kind: FSKind) -> Bool {
    switch target {
        case .anything: return kind != .free
        case .file: return kind == .file
        case .place: return kind == .folder || kind == .container
    }
}

private func pathKind(_ kind: FSKind) -> StaticString {
    switch kind {
        case .free: return ""
        case .file: return "File"
        case .folder: return "Folder"
        case .container: return "Container"
    }
}


private func listFiles(
    _ files    : FileSystemClient,
      in folder: UInt32
) {

    withUnsafeTemporaryAllocation(
        of: UInt8.self, capacity: listBatchSize * FSListEntry.width
    ) { room in
        let base = UnsafeMutableRawPointer(room.baseAddress!)

        var cursor = UInt32(0)
        var seen   = 0

        // Printed before anything is judged, and that order is the point: a
        // batch that found six names and then lost the disk is six names this
        // shell knows about, and hiding them because of what came after would be
        // hiding what it was asked for. The step hands them over with the
        // verdict, so the two cannot come apart.
        func show(_ count: Int) {
            for index in 0..<count {
                let entry = FSListEntry(
                    reading: base.advanced(by: index * FSListEntry.width)
                )

                _ = FileSystemOutput.records.appendFileSystemEntry(
                    kind : entry.kind,
                    name : entry.name,
                    count: Int(entry.length)
                )

                seen += 1
            }
        }

        walk: while true {
            let batch = files.listBatch(
                folder, from: cursor, into: base, capacity: listBatchSize
            )

            switch batch.step {
                case .more(let found):
                    show(found)
                    cursor = batch.next

                // The one thing that ends the loop. Not an empty batch and not a
                // refusal: the server says where the folder ends.
                case .end(let found):
                    show(found)
                    break walk

                // And an error is said even after a partial result. It used to be
                // indistinguishable from the end of the folder, so it was only
                // ever reported when there had been nothing at all to show.
                case .stopped(let found, let why):
                    show(found)
                    report(why)
                    return
            }
        }

        if seen == 0 { _ = FileSystemOutput.records.appendFileSystemEmpty() }
    }
}


/// What something is, and when it was made and last changed.
private func explain(
    _ files: FileSystemClient,
    name   : UnsafeRawPointer,
    length : Int,
    in folder: UInt32
) {
    let opened = files.open(name, length: length, in: folder)

    guard opened.status == .ok, let file = opened.file else {
        report(opened.status)
        return
    }

    guard let info = files.info(of: file.object) else {
        report(.notFound)
        return
    }

    _ = FileSystemOutput.records.appendFileSystemInfo(
        kind    : info.kind,
        size    : info.size,
        blocks  : info.blocks,
        created : info.created.nanoseconds,
        modified: info.modified.nanoseconds
    )
}


private func readFile(
    _ files: FileSystemClient,
    name   : UnsafeRawPointer,
    length : Int,
    in folder: UInt32
) {
    let opened = files.open(name, length: length, in: folder)

    guard opened.status == .ok, let file = opened.file else {
        report(opened.status)
        return
    }

    guard file.kind == .file else {
        FileSystemOutput.literal("that is not a file\n")
        return
    }

    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 512) { buffer in
        let read = files.read(
            file.object,
            at   : 0,
            into : UnsafeMutableRawPointer(buffer.baseAddress!),
            count: 512
        )

        guard read.status == .ok else {
            report(read.status)
            return
        }

        var offset = 0
        while offset < Int(read.bytes) {
            let first     = offset == 0
            let remaining = Int(read.bytes) - offset
            let amount    = ShellTextChunking.amount(remaining: remaining, first: first)
            let last      = amount == remaining
            guard FileSystemOutput.records.appendFileSystemRead(buffer.baseAddress! + offset, count: amount, first: first, last: last) else { break }
            offset += amount
        }

        if file.size > read.bytes {
            _ = FileSystemOutput.records.appendFileSystemReadTail(shown: read.bytes, total: file.size)
        }
    }
}


/// Makes the file say this and nothing else.
///
/// `replace` and not `write`: typing a shorter line over a longer file means
/// the file now says the shorter thing, which is not what writing at an offset
/// does. One request, so nobody sees it half replaced.
private func writeFile(
    _ files: FileSystemClient,
    name   : UnsafeRawPointer,
    length : Int,
    in folder: UInt32,
    text   : UnsafeRawPointer,
    count  : Int
) {
    var object = files.open(name, length: length, in: folder).file?.object

    if object == nil {
        let made = files.create(name, length: length, kind: .file, in: folder)
        guard made.status == .ok else {
            report(made.status)
            return
        }
        object = made.file?.object
    }

    guard let object else { return }

    let written = files.replaceAll(object, from: text, count: UInt64(count))

    guard written.status == .ok else {
        report(written.status)
        return
    }

    _ = FileSystemOutput.records.appendFileSystemWrite(written.bytes)
}


/// A refusal in words rather than a number.
func report(_ status: FSStatus) {
    FileSystemOutput.status(status)
}
