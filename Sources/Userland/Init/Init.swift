//
//  init.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.

import Reix

@_cdecl("_start")
public func main() {

    print("[ INIT  ] Hi, this is init process!\n")

    // The machine boots not knowing the date. There is no battery clock here
    // and no network to ask, so somebody has to say, and init is the only one
    // holding the capability that lets it. Until this line the clock reads
    // zero, which is not a date but an admission.
    //
    // TODO: - the time comes from the build for now. A real one comes from a
    // hardware clock or from whoever logs in, and this is the line that
    // changes when it does.
    if let clock = environmentClock(), let boot = Time(BuildStamp.civil) {
        _ = SystemClock.set(boot, authority: clock)
    }

    // The kernel installs the full profiler authority at this fixed slot before
    // init runs, which is why it can be named rather than looked up.
    let profiler = BootCap.profiler.rawValue

    profileControl(.enable, authority: profiler, arg: 0xFF)
    profileControl(.setSampleDivider, authority: profiler, arg: 1)

    guard let device = deviceCap() else { return }

    let console = withUnsafeTemporaryAllocation(
        of      : CapGrant.self,
        capacity: 1
    ) { buffer in

        buffer[0] = CapGrant(
            source: device,
            slot  : BootCap.device.rawValue,
            rights: [.grant, .read, .write]
        )

        return spawnProcess(
            path  : "ConsoleServer.elf",
            grants: buffer.baseAddress!,
            count : 1
        )
    }

    guard let consoleEndpoint = receive(
        handle: console.handle
    ).grantedCap else { return }

    Console.attach(console: consoleEndpoint)

    print("[ INIT  ] Console attached, launching Name Server")

    let nameServer = launch(
        "NameServer.elf",
        environment: Environment(
            console   : consoleEndpoint,
            nameServer: nil,
            spawn     : nil
        )
    )
    guard let nameServerEndpoint = receive(
        handle: nameServer.handle
    ).grantedCap else { return }

    guard let spawnCap = spawnService() else { return }

    let environment = Environment(
        console   : consoleEndpoint,
        nameServer: nameServerEndpoint,
        spawn     : spawnCap
    )

    // TODO: - the Process Server was launched here, with a registrar capability
    // minted for the one name it may publish. It is disabled until the file
    // system can hand it an image: see Sources/Userland/ProcessServer. What
    // comes back with it is the `derive` of `NameServerSession.registrar(for:)`
    // above this line, which is the only place in the boot that mints one, so
    // nothing publishes a name while it is gone.

    // Narrowed to `.profileStats` on the way in by `ProfileAuthorityGrant.tool`:
    // a stats reader has no business dumping the trace ring over the console.
    sleep(for: .milliseconds(800))

    print("")
    print("============ PROFILE DUMP ============")
    print("\n")

    profileDump(authority: profiler)

    profileControl(.enable, authority: profiler, arg: 0x3F)

    // The terminal server: it holds the serial window and the interrupt line
    // that goes with it, and it is the only process that does. Assembled here
    // rather than through `launch` because neither is ambient: every process
    // inherits the console, exactly one owns the keyboard.
    let terminal = withUnsafeTemporaryAllocation(
        of      : CapGrant.self,
        capacity: 3
    ) { grants in

        grants[0] = CapGrant(
            source: consoleEndpoint,
            slot  : BootCap.console.rawValue,
            rights: [.send, .grant]
        )
        grants[1] = CapGrant(
            source: device,
            slot  : BootCap.device.rawValue,
            rights: [.grant, .read, .write]
        )
        grants[2] = CapGrant(
            source: BootCap.interrupt.rawValue,
            slot  : BootCap.interrupt.rawValue,
            rights: [.grant]
        )

        return spawnProcess(
            path  : "TerminalServer.elf",
            grants: grants.baseAddress!,
            count : 3
        )
    }

    guard let terminalEndpoint = receive(
        handle: terminal.handle
    ).grantedCap else { return }

    // The bus walker, when the machine described a bus. It reads device ids and
    // starts a driver for what it finds, so all it needs is to spawn. It gets
    // no window and no line of its own: those it carves. And no registrar and
    // no name server either, because the disk is not a thing with a name.
    //
    // The whole disk comes back out of this: the driver hands its endpoint to
    // the bus, the bus checks the sectors while it is still the only process
    // that can reach them, and then hands it here and keeps nothing.
    var disk      : UInt32? = nil
    var diagnostic: UInt32? = nil
    var warden    : UInt32? = nil

    if capExists(BootCap.virtioBus.rawValue) {
        let bus = withUnsafeTemporaryAllocation(
            of      : CapGrant.self,
            capacity: 3
        ) { grants in

            grants[0] = CapGrant(
                source: consoleEndpoint,
                slot  : BootCap.console.rawValue,
                rights: [.send, .grant]
            )
            grants[1] = CapGrant(
                source: BootCap.virtioBus.rawValue,
                slot  : BootCap.virtioBus.rawValue,
                // `.grant` and not only `.derive`: what it carves it has to be
                // able to hand to the driver it starts, and a window it cannot
                // pass on is a window it would have to use itself.
                //
                // `.dma` because a disk driver has to put a ring where the disk
                // can read it, and on a machine with nothing between a device
                // and memory that means handing it the whole of memory. This is
                // where that is decided: drop it here and no process this
                // machine runs can turn an address into a physical one.
                rights: [.grant, .derive, .read, .write, .dma]
            )
            grants[2] = CapGrant(
                source: spawnCap,
                slot  : BootCap.spawn.rawValue,
                rights: [.spawn]
            )

            return spawnProcess(
                path  : "VirtioBus.elf",
                grants: grants.baseAddress!,
                count : 3
            )
        }

        // Waited for on purpose, and this is the one place the boot is
        // deliberately sequential: nothing above the disk may exist before it
        // is known who holds it. The bus always answers, with the disk or
        // without, so a machine with no block device carries on from here.
        if bus.hasEndpoint {
            disk = receive(handle: bus.handle).grantedCap
        }

        // Two views, both cut before the disk is given away, because afterwards
        // init holds nothing to cut them from.
        //
        // The first is for looking: it cannot write a byte, cannot claim the
        // volume, and while somebody holds the volume cannot read one either.
        // `.grant` is the right to hand it on and not a right over the disk -
        // the shell gets `.send` and nothing else below, and rights only ever
        // narrow on the way down.
        //
        // The second is narrower still, and is the one init keeps: a warden may
        // say that whoever held the volume is gone, and may do nothing else at
        // all. Init holds it because init started the file system, so init is
        // the process the kernel wakes when the file system dies. Nothing else
        // on the machine is told.
        if let disk {
            diagnostic = derive(
                handle : disk,
                session: BlockOperation.Badge.readOnly,
                rights : [.send, .grant]
            )
            warden = derive(
                handle : disk,
                session: BlockOperation.Badge.warden,
                rights : [.send]
            )
        }
    }

    // The file system, which needs no hardware at all: it is handed the disk
    // and holds the only mounted copy of the format.
    //
    // It publishes no name. What it does instead is hand back one capability,
    // bound to the machine's own container, and everything anybody ever sees of
    // the disk is carved out of that by somebody who already had it. Init is
    // the somebody, because Init is what started it.
    var machine : UInt32? = nil
    var filesPid: PID?    = nil

    if let disk {
        let files = withUnsafeTemporaryAllocation(
            of      : CapGrant.self,
            capacity: 2
        ) { grants in

            grants[0] = CapGrant(
                source: consoleEndpoint,
                slot  : BootCap.console.rawValue,
                rights: [.send, .grant]
            )
            // `.send` and nothing else. No `.grant`, so the file system cannot
            // pass the disk to anybody; no `.derive`, so it cannot cut a view
            // of it either. It is the only process that may write the volume
            // and the last one that may say who else does.
            grants[1] = CapGrant(
                source: disk,
                slot  : BootCap.block.rawValue,
                rights: [.send]
            )

            return spawnProcess(
                path  : "FileSystemServer.elf",
                grants: grants.baseAddress!,
                count : 2
            )
        }

        machine  = awaitContainer(from: files.handle)
        filesPid = files.pid

        // Given away, so not held. From here nobody in the machine can reach a
        // raw sector for writing except the process that mounted it.
        _ = capDrop(disk)
    }

    if let machine {
        startStorageCheck(
            machine    : machine,
            environment: environment,
            diagnostic : diagnostic
        )
    }

    // After the storage check, not before: it is handed the same view.
    if let diagnostic { _ = capDrop(diagnostic) }

    // Counted as they are written rather than placed at fixed indices: which
    // capabilities the shell gets depends on what this machine turned out to
    // have, and an index worked out from two optionals is an index that gets
    // worked out wrong.
    _ = withUnsafeTemporaryAllocation(
        of      : CapGrant.self,
        capacity: 8
    ) { grants in

        var count = 0

        func give(_ grant: CapGrant) {
            grants[count] = grant
            count += 1
        }

        give(CapGrant(
            source: consoleEndpoint,
            slot  : BootCap.console.rawValue,
            rights: [.send, .grant]
        ))
        // Lookup only. The shell can find the services that have names; it
        // cannot publish one, which is what would let it answer as one. The
        // disk is not among them any more.
        give(CapGrant(
            source: nameServerEndpoint,
            slot  : BootCap.nameServer.rawValue,
            rights: [.send]
        ))
        give(CapGrant(
            source: spawnCap,
            slot  : BootCap.spawn.rawValue,
            rights: [.spawn, .grant]
        ))
        give(CapGrant(
            source: terminalEndpoint,
            slot  : BootCap.terminal.rawValue,
            rights: [.send, .grant]
        ))
        // `launcher` and not `tool`: the shell has to be able to pass a
        // reader's share to the commands it runs, and what it passes drops the
        // right to pass it further.
        give(ProfileAuthorityGrant.launcher(source: profiler))

        // The whole machine, because the person at the keyboard is meant to see
        // the whole disk. Not a privilege the shell has: a capability it was
        // handed, exactly like every narrower one below it.
        if let machine {
            give(CapGrant(
                source: machine,
                slot  : BootCap.container.rawValue,
                rights: [.send, .grant]
            ))
        }

        // And the disk underneath it, to look at and not to touch. Reading raw
        // sectors is how you find out whether the layer above is telling the
        // truth, so the shell keeps that; what it no longer has is any way to
        // write one, or to read one while the file system is mounted.
        if let diagnostic {
            give(CapGrant(
                source: diagnostic,
                slot  : BootCap.block.rawValue,
                rights: [.send]
            ))
        }

        // And the right to stop the machine, for the same reason: the person at
        // the keyboard is the one who turns it off.
        if capExists(BootCap.power.rawValue) {
            give(CapGrant(
                source: BootCap.power.rawValue,
                slot  : BootCap.power.rawValue,
                rights: [.write]
            ))
        }

        return spawnProcess(
            path  : "Shell.elf",
            grants: grants.baseAddress!,
            count : count
        )
    }

    if let warden, let filesPid {
        awaitFileSystem(pid: filesPid, warden: warden)
    }

    while true {
        sleep(for: .seconds(1))
    }
}


/// Waits for the machine's container, answering the one question the file
/// system may ask on the way.
///
/// That question is whether an empty disk may be formatted, and init is asked
/// because init is what handed the disk over. The answer is yes for an empty
/// disk and the question is never put for any other kind: a disk with something
/// on it that this build cannot read is refused by the file system itself,
/// unread and unwritten, and the machine comes up without one.
///
/// So there is exactly one place in the system where a disk gets erased, it is
/// reached by a request and a reply between two processes, and the request is
/// only ever made about a disk that is provably empty.
private func awaitContainer(from files: UInt32) -> UInt32? {

    // Bounded, and only as a backstop. A file system that refuses the disk says
    // so before it stops, so the usual failure is answered rather than waited
    // out; this is for one that faults without a word. Either way init must not
    // wait here for ever, because a machine whose disk cannot be read is
    // exactly the machine somebody wants a shell on.
    let patience: UInt32 = 500      // ticks, ten milliseconds each

    for _ in 0..<2 {
        guard var answer = receive(handle: files, timeout: patience) else {
            print("[ INIT  ] the file system never answered, carrying on without one")
            return nil
        }

        switch answer.message.tag.label {

            case BootMessage.blankDisk.rawValue:
                print("[ INIT  ] the disk is empty, telling the file system to format it")
                _ = reply(message: BootMessage.allowed.message)

            case BootMessage.refused.rawValue:
                print("[ INIT  ] the disk holds nothing this build can mount, so there is no file system")
                return nil

            default:
                guard let handed = answer.takeGrant() else {
                    print("[ INIT  ] the file system gave back no container")
                    return nil
                }

                return handed
        }
    }

    return nil
}


/// Waits for the file system to die, and gives the volume back when it does.
///
/// `reapChild` parks this process until that one child is gone: no polling, no
/// timer, and nothing to get wrong about when to look. It comes back for one
/// reason only - there is no live child with that pid any more - which is
/// exactly the condition under which letting the volume go is safe.
///
/// What goes back is the claim, and the window the dead process left mapped in
/// the block server. Not one byte of the disk is touched, and that is the whole
/// of why this cannot cost anybody a file: the format is still marked mounted,
/// so the next process to mount runs its check and puts right whatever the
/// crash left half done. Everything that was written stays written.
///
/// Init blocks here for the rest of a healthy boot, which is what it did before
/// in a sleep loop. A child that dies while init waits on a different one still
/// dies properly; it is simply not reaped, which was already true.
private func awaitFileSystem(
      pid   : PID,
      warden: UInt32
) {

    _ = reapChild(for: pid)

    guard case .success(let answer) = call(
        handle : warden,
        message: BlockOperation.reclaim.request
    ), BlockOperation.status(of: answer.message) == .ok else {
        print("[ INIT  ] the file system is gone and the volume stayed held")
        return
    }

    print("[ INIT  ] the file system is gone, the volume is free again")
}


/// The clock capability, if this build of the kernel minted one.
private func environmentClock() -> UInt32? {
    capExists(BootCap.clock.rawValue) ? BootCap.clock.rawValue : nil
}


/// When this image was built, as the machine's first guess at the date.
///
/// A guess and labelled as one: it is right the first time the image runs and
/// wrong every time after, which is exactly as much as a machine with no clock
/// hardware can honestly claim.
private enum BuildStamp {
    static let civil = Civil(year: 2026, month: 8, day: 23, hour: 12, minute: 0, second: 0)
}


/// How many bytes of gift there are, and what they are.
///
/// Position-dependent so a transfer that repeats or shifts a block fails the
/// comparison at the far end instead of passing it.
private let giftSize = 2000

private func giftByte(_ index: Int) -> UInt8 {
    UInt8((index * 7 + 13 + (index >> 8) * 31) & 0xFF)
}


/// Makes a container for the storage check and starts it inside that and
/// nothing else, then hands it a piece of somewhere else two different ways.
///
/// This is the model end to end. Init holds the machine, cuts a room out of it
/// with a size, and gives away a capability naming only that room. Then it puts
/// a file in a *different* container and lets the child at it twice: once by
/// handing over a read-only capability naming that one file and nothing around
/// it, and once by copying the bytes down a pipe, where the child gets the
/// bytes and learns nothing else at all.
private func startStorageCheck(
    machine    : UInt32,
    environment: Environment,
    diagnostic : UInt32?
) {

    guard let files = FileSystemClient(fileSystem: machine) else {
        print("[ INIT  ] cannot attach to the machine's container")
        return
    }

    guard let container = place(files, "check", room: 64),
          let vault     = place(files, "vault", room: 32)
    else { return }

    guard let gift = fillGift(files, in: vault) else { return }

    // A tenant, not an administrator. It keeps files in a container of its own
    // and hands one piece of it back to a child of its own, so it needs to
    // delegate; what it has no business doing is moving room between
    // containers, speaking for the volume, or unmounting the disk out from
    // under everybody else holding a piece of it.
    guard let handed = files.bind(container, rights: FSRights.occupant.union(.delegate)),
          let lent   = files.bind(gift, rights: .reader)
    else {
        print("[ INIT  ] cannot hand over what the storage check needs")
        return
    }

    // Four when there is a disk to look at, three when there is not. The fourth
    // is the same read-only view the shell gets, and nothing more.
    let count = diagnostic == nil ? 3 : 4

    let child = withUnsafeTemporaryAllocation(of: CapGrant.self, capacity: 4) { grants in

        grants[0] = CapGrant(
            source: environment.console!,
            slot  : BootCap.console.rawValue,
            rights: [.send, .grant]
        )
        grants[1] = CapGrant(
            source: handed,
            slot  : BootCap.container.rawValue,
            rights: [.send, .grant]
        )
        // One file out of a container the child has no other way into, and it
        // may only look at it.
        grants[2] = CapGrant(
            source: lent,
            slot  : BootCap.shared.rawValue,
            rights: [.send, .grant]
        )

        if let diagnostic {
            grants[3] = CapGrant(
                source: diagnostic,
                slot  : BootCap.block.rawValue,
                rights: [.send]
            )
        }

        return spawnProcess(
            path  : "StorageCheck.elf",
            grants: grants.baseAddress!,
            count : count
        )
    }

    _ = capDrop(handed)
    _ = capDrop(lent)

    guard child.hasEndpoint else { return }

    pourGift(files, gift: gift, to: child.handle)

    orphanedClaim(files, in: container, of: child.pid)
}


/// Writes a file the dead storage check was still holding a claim on.
///
/// The other half of `claimAbandoned` in StorageCheck, and the reason it needs
/// two processes: a claim is an application lock, so one held by a corpse is a
/// file nobody can ever write again. Nothing tells the file system that a client
/// has died - it asks, when a refusal is about to be the answer.
///
/// `reapChild` first, and not a sleep: it comes back for one reason only, that
/// there is no live process with that pid, which is the condition the whole check
/// is about. Written and not unlocked, because a `lock` from here would say the
/// claim table let go while a write says the *refusal* did.
private func orphanedClaim(
    _ files       : FileSystemClient,
      in container: UInt32,
      of pid      : PID
) {

    _ = reapChild(for: pid)

    let name  = "orphan.bin" as StaticString
    let bytes = UnsafeRawPointer(name.utf8Start)

    guard let file = files.open(
        bytes, length: name.utf8CodeUnitCount, in: container
    ).file?.object else {
        print("[ INIT  ] the file the storage check died holding is not there")
        return
    }

    var payload: UInt8 = 0x5A

    let written = withUnsafePointer(to: &payload) {
        files.write(file, at: 0, from: UnsafeRawPointer($0), count: 1)
    }

    guard written.status == .ok else {
        print("[ INIT  ] a claim its holder took to the grave still refuses everybody")
        return
    }

    print("[ INIT  ] a claim whose holder died was let go")
}


/// The container called `name`, made if this is the first boot to want it.
private func place(
    _ files: FileSystemClient,
    _ name : StaticString,
      room : UInt32
) -> UInt32? {

    let bytes = UnsafeRawPointer(name.utf8Start)
    let count = name.utf8CodeUnitCount

    if let existing = files.open(bytes, length: count).file?.object { return existing }

    let made = files.createContainer(bytes, length: count, room: room)

    guard made.status == .ok, let object = made.file?.object else {
        print("[ INIT  ] no room for a container the storage check needs")
        return nil
    }

    return object
}


/// Writes the gift into the vault and answers the file.
private func fillGift(
    _ files   : FileSystemClient,
      in vault: UInt32
) -> UInt32? {

    let name  = "gift.txt" as StaticString
    let bytes = UnsafeRawPointer(name.utf8Start)
    let count = name.utf8CodeUnitCount

    var file = files.open(bytes, length: count, in: vault).file?.object

    if file == nil {
        let made = files.create(bytes, length: count, kind: .file, in: vault)
        guard made.status == .ok else {
            print("[ INIT  ] the gift could not be made")
            return nil
        }
        file = made.file?.object
    }

    guard let file else { return nil }

    let payload = UnsafeMutableRawPointer.allocate(byteCount: giftSize, alignment: 8)
    defer { payload.deallocate() }

    let out = payload.assumingMemoryBound(to: UInt8.self)
    for index in 0..<giftSize { out[index] = giftByte(index) }

    guard files.write(file, at: 0, from: UnsafeRawPointer(payload), count: UInt64(giftSize)).status == .ok
    else {
        print("[ INIT  ] the gift could not be written")
        return nil
    }

    return file
}


/// Copies the gift down a pipe, a page at a time.
///
/// The other end gets bytes and nothing else: no object number, no name, no way
/// to ask for anything more. It is the same file the child can also read
/// through the capability it was handed, which is what lets it check the two
/// against each other.
private func pourGift(
    _ files      : FileSystemClient,
      gift       : UInt32,
      to endpoint: UInt32
) {

    guard var producer = PipeProducer(to: endpoint) else {
        print("[ INIT  ] no pipe to pour the gift down")
        return
    }

    var offset = UInt64(0)

    let poured = producer.pump { page, capacity in
        let room = UInt64(capacity)
        let left = UInt64(giftSize) - offset

        guard left > 0 else { return PipeFill(.ok) }

        let wanted = left < room ? left : room
        let read   = files.read(gift, at: offset, into: page, count: wanted)

        guard read.status == .ok, read.bytes > 0 else { return PipeFill(.sourceFailed) }

        offset += read.bytes
        return PipeFill(.ok, Int(read.bytes))
    }

    if poured != .ok { print("[ INIT  ] the pipe transfer was refused") }
}
