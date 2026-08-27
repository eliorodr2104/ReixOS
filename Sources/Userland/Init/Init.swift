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

    guard let registrar = derive(
        handle : nameServerEndpoint,
        session: UInt64(NameServerSession.registrar),
        rights : [.send, .grant]

    ) else {
        print("[ INIT  ] cannot mint the Name Server registrar capability")
        return
    }

    guard let spawnCap = spawnService() else { return }

    let environment = Environment(
        console   : consoleEndpoint,
        nameServer: nameServerEndpoint,
        spawn     : spawnCap
    )

    // TODO: - the Process Server was launched here, with a registrar capability
    // minted for the one name it may publish. It went with the images it existed
    // to start: it named a program by an enum the build compiled in, and what
    // comes back in its place reads one off the volume. Nothing publishes a name
    // while it is gone, because minting the registrar was the only place a name
    // could be claimed.

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
    var disk  : UInt32? = nil
    var warden: UInt32? = nil

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

        // Cut before the disk is given away, because afterwards init holds
        // nothing to cut it from.
        //
        // A warden may say that whoever held the volume is gone, and may do
        // nothing else at all. Init holds it because init started the file
        // system, so init is the process the kernel wakes when the file system
        // dies. Nothing else on the machine is told.
        if let disk {
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

    // Held and handed to nobody. The machine's container is the root every
    // narrower view is cut from, and there is not yet a program that has been
    // given one, so it stops here.
    if machine != nil {
        print("[ INIT  ] the machine's container is held, with nobody to give it to yet\n")
    }

    _ = withUnsafeTemporaryAllocation(
        of      : CapGrant.self,
        capacity: 4
    ) { grants in

        grants[0] = CapGrant(
            source: consoleEndpoint,
            slot  : BootCap.console.rawValue,
            rights: [.send, .grant]
        )
        grants[1] = CapGrant(
            source: spawnCap,
            slot  : BootCap.spawn.rawValue,
            rights: [.spawn, .grant]
        )
        grants[2] = CapGrant(
            source: terminalEndpoint,
            slot  : BootCap.terminal.rawValue,
            rights: [.send, .grant]
        )
        // `launcher` and not `tool`: the shell has to be able to pass a
        // reader's share to the commands it runs, and what it passes drops the
        // right to pass it further.
        grants[3] = ProfileAuthorityGrant.launcher(source: profiler)

        return spawnProcess(
            path  : "Shell.elf",
            grants: grants.baseAddress!,
            count : 4
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
private func awaitFileSystem(pid: PID, warden: UInt32) {

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
