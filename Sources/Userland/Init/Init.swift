//
//  init.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.

import Reix

@_cdecl("_start")
public func main() {

    UserBootPresentation.ready("[ INIT  ] Hi, this is init process!")
    UserBootPresentation.milestone(.userland)

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

    #if REIX_TERMINAL_PROFILE
    profileControl(.enable, authority: profiler, arg: 0x1FF)
    #else
    profileControl(.enable, authority: profiler, arg: 0xFF)
    #endif

    profileControl(.setSampleDivider, authority: profiler, arg: 1)

    guard let device = deviceCap() else {
        return
    }

    let serial = withUnsafeTemporaryAllocation(
        of      : CapGrant.self,
        capacity: 2

    ) { buffer in

        buffer[0] = CapGrant(
            source: device,
            slot  : BootCap.device.rawValue,
            rights: [.read, .write]
        )

        buffer[1] = CapGrant(
            source: BootCap.interrupt.rawValue,
            slot  : BootCap.interrupt.rawValue,
            rights: []
        )

        return spawnProcess(
            path: "SerialServer.elf",
            grants: buffer.baseAddress!,
            count: 2
        )
    }
    guard let serialEndpoint = receive(handle: serial.handle).grantedCap,
          let readerAccess = ReixSerialAccess(role: .reader, channel: 1),
          let writerAccess = ReixSerialAccess(role: .writer, channel: 1),
          let serialReader = derive(handle: serialEndpoint, session: readerAccess.rawValue, rights: [.send, .grant]),
          let serialWriter = derive(handle: serialEndpoint, session: writerAccess.rawValue, rights: [.send, .grant])
    else { return }

    _ = capDrop(serial.handle)
    _ = capDrop(serialEndpoint)
    _ = capDrop(device)
    _ = capDrop(BootCap.interrupt.rawValue)

    let console = withUnsafeTemporaryAllocation(
        of      : CapGrant.self,
        capacity: 1
    ) { buffer in

        buffer[0] = CapGrant(
            source: serialWriter,
            slot  : BootCap.serialWriter.rawValue,
            rights: [.send]
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
    _ = capDrop(console.handle)
    _ = capDrop(serialWriter)

    Console.attach(console: consoleEndpoint)

    UserBootPresentation.ready("[ INIT  ] Console attached, launching Name Server")

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
    _ = capDrop(nameServer.handle)

    guard let spawnCap = spawnService() else { return }

    // Narrowed to `.profileStats` on the way in by `ProfileAuthorityGrant.tool`:
    // a stats reader has no business dumping the trace ring over the console.
    sleep(for: .milliseconds(800))

    // The whole trace ring over the console, which is hundreds of lines and the
    // noisiest thing this machine prints. Only `diagnostic` asks for it.
    if UserBootPresentation.showsServices {
        print("")
        print("============ PROFILE DUMP ============")
        print("\n")

        profileDump(authority: profiler)
    }

    #if REIX_TERMINAL_PROFILE
    // Start the terminal workload with an empty ring so traceLost belongs to
    // this run, rather than to boot activity retained for the normal image.
    profileControl(.reset, authority: profiler)
    // Keep only interaction marks while Shell scans process statistics: IPC and
    // context events would otherwise displace the bounded profiling correlation
    // trace. The normal 0x3F suite already covers those general categories.
    profileControl(.enable, authority: profiler, arg: 0x100)
    #else
    profileControl(.enable, authority: profiler, arg: 0x3F)
    #endif

    let inputServer = withUnsafeTemporaryAllocation(
        of      : CapGrant.self,
        capacity: 1
    ) { grants in

        grants[0] = CapGrant(
            source: consoleEndpoint,
            slot  : BootCap.console.rawValue,
            rights: [.send]
        )

        return spawnProcess(
            path  : "InputServer.elf",
            grants: grants.baseAddress!,
            count : 1
        )
    }

    guard let inputEndpoint = receive(handle: inputServer.handle).grantedCap,
          let sourceAccess = ReixInputAccess(role: .source, session: 1),
          let consumerAccess = ReixInputAccess(role: .consumer, session: 1),
          let focusAccess = ReixInputAccess(role: .focusController, session: 1),
          let inputSource = derive(handle: inputEndpoint, session: sourceAccess.rawValue, rights: [.send, .grant]),
          let inputConsumer = derive(handle: inputEndpoint, session: consumerAccess.rawValue, rights: [.send, .grant]),
          let inputFocus = derive(handle: inputEndpoint, session: focusAccess.rawValue, rights: [.send])
    else { return }
    _ = capDrop(inputServer.handle)
    _ = capDrop(inputEndpoint)

    let focusWords = InlineArray<4, UInt32>(repeating: 0)
    guard case .success(let focusReply) = call(
        handle : inputFocus,
        message: Message(
            tag: MessageTag(
                ReixInputServerOperation.focus,
                length: 0
            ),
            words: focusWords
        )

    ), focusReply.message.words[0] == ReixInputServerStatus.pending.rawValue
    else { return }

    // VTAdapter receives only the semantic input and presentation channels.
    let terminal = withUnsafeTemporaryAllocation(
        of      : CapGrant.self,
        capacity: {
            #if REIX_TERMINAL_PROFILE
            4
            #else
            3
            #endif
        }()
    ) { grants in

        grants[0] = CapGrant(
            source: consoleEndpoint,
            slot  : BootCap.console.rawValue,
            rights: [.send]
        )

        grants[1] = CapGrant(
            source: inputSource,
            slot  : BootCap.inputSource.rawValue,
            rights: [.send]
        )

        grants[2] = CapGrant(
            source: serialReader,
            slot: BootCap.serialReader.rawValue,
            rights: [.send]
        )
        #if REIX_TERMINAL_PROFILE
        // Marker-only: no console dump and no delegation authority.
        grants[3] = ProfileAuthorityGrant.marker(source: profiler, console: false)
        #endif

        return spawnProcess(
            path  : "VTAdapter.elf",
            grants: grants.baseAddress!,
            count : {
                #if REIX_TERMINAL_PROFILE
                4
                #else
                3
                #endif
            }()
        )
    }

    guard let terminalEndpoint = receive(
        handle: terminal.handle
    ).grantedCap else { return }
    _ = capDrop(terminal.handle)
    _ = capDrop(inputSource)
    _ = capDrop(serialReader)
    _ = capDrop(consoleEndpoint)

    // From this point every ordinary producer writes to the semantic terminal
    // consumer. Only VTAdapter retains the transport-only ConsoleServer cap.
    Console.attach(console: terminalEndpoint)
    let terminalEnvironment = Environment(
        console     : terminalEndpoint,
        nameServer  : nameServerEndpoint,
        spawn       : spawnCap,
        serialReader: serialReader
    )

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
                source: terminalEndpoint,
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
            _ = capDrop(bus.handle)
        }
        _ = capDrop(BootCap.virtioBus.rawValue)

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
                source: terminalEndpoint,
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
        _ = capDrop(files.handle)

        // Given away, so not held. From here nobody in the machine can reach a
        // raw sector for writing except the process that mounted it.
        _ = capDrop(disk)
    }

    // The storage stack end to end, copy-on-write, and the frame budget. A test
    // suite rather than a boot step, so only the mode whose job is answering
    // questions runs it: the others reach the shell without the twenty-five
    // `[ CHECK ]` lines, the seconds they cost, or the fault the NX check
    // provokes on purpose and the kernel is right to report.
    if let machine, UserBootPresentation.showsServices {
        startStorageCheck(
            machine    : machine,
            environment: terminalEnvironment,
            diagnostic : diagnostic
        )

        copyOnWriteSelfCheck()

        frameBudgetSelfCheck()
    }

    // The shell gets every filesystem right except `unmount`; the
    // administrative root stays in Init, which the server intersects against.
    let shellMachine = machine.flatMap { endpoint -> UInt32? in
        guard let files = FileSystemClient(fileSystem: endpoint) else { return nil }
        return files.bind(files.root, rights: .everything.subtracting(.unmount))
    }

    // The executable namespace is rooted exactly at `system/programs`, and
    // carries lookup and read on that directory's children.
    let programs = machine.flatMap(programDirectory(in:))
    if programs == nil {
        print("[ INIT  ] no system/programs capability; ordinary programs stay stopped")
    }

    // The task bootstrap endpoint is gone after Ready, so shutdown and A/B
    // replacement need an endpoint of their own.
    let sessionEndpoint = spawnEndpoint()

    // ProcessServer is still an initrd bootstrap service. It gets the legacy
    // spawn authority taskCreate needs, plus what its profiles may attenuate.
    let processServer = programs.map { programDirectory in
        withUnsafeTemporaryAllocation(
        of      : CapGrant.self,
        capacity: {
            #if REIX_TERMINAL_PROFILE
            ShellGrantCapacity.terminalProfile
            #else
            ShellGrantCapacity.normal
            #endif
        }()
        ) { grants in

            var count = 0

            func give(_ grant: CapGrant) {
                precondition(count < grants.count)
                grants[count] = grant
                count += 1
            }

            give(CapGrant(
                source: terminalEndpoint,
                slot  : BootCap.console.rawValue,
                rights: [.send, .grant]
            ))
            give(CapGrant(
                source: spawnCap,
                slot  : BootCap.spawn.rawValue,
                rights: [.spawn]
            ))
            give(ProfileAuthorityGrant.launcher(source: profiler))
            give(CapGrant(
                source: nameServerEndpoint,
                slot  : BootCap.nameServer.rawValue,
                rights: [.send, .grant]
            ))
            give(CapGrant(
                source: inputConsumer,
                slot  : BootCap.inputConsumer.rawValue,
                rights: [.send, .grant]
            ))

            if let shellMachine {
                give(CapGrant(
                    source: shellMachine,
                    slot  : BootCap.container.rawValue,
                    rights: [.send, .grant]
                ))
            }

            give(CapGrant(
                source: programDirectory,
                slot  : BootCap.programs.rawValue,
                rights: [.send, .grant]
            ))
            give(CapGrant(
                source: sessionEndpoint,
                slot  : BootCap.sessionControl.rawValue,
                rights: [.send, .grant]
            ))

            if let diagnostic {
                give(CapGrant(
                    source: diagnostic,
                    slot  : BootCap.block.rawValue,
                    rights: [.send, .grant]
                ))
            }

            #if REIX_TERMINAL_PROFILE
            // ProcessServer may pass the measured workload its marker share;
            // the program profile removes `grant` again before Shell sees it.
            give(ProfileAuthorityGrant.markerLauncher(source: profiler))
            #endif

            return spawnProcess(
                path  : "ProcessServer.elf",
                grants: grants.baseAddress!,
                count : count
            )
        }
    }

    let processServerEndpoint = processServer.flatMap { spawned -> UInt32? in
        guard spawned.hasEndpoint else {
            print("[ INIT  ] ProcessServer bootstrap spawn was refused")
            return nil
        }

        guard var announcement = receive(handle: spawned.handle, timeout: 500),
              announcement.message.tag.label == BootMessage.announce.rawValue,
              let endpoint = announcement.takeGrant()
        else {
            print("[ INIT  ] ProcessServer did not publish an endpoint")
            return nil
        }

        UserBootPresentation.ready("[ INIT  ] ProcessServer endpoint ready")
        return endpoint
    }

    let shellJob = processServerEndpoint.flatMap { endpoint -> UInt32? in
        let name     : StaticString = "Shell.elf"
        let launched = launchProgram(
            through: endpoint,
            name   : name.utf8Start,
            length : name.utf8CodeUnitCount
        )
        guard launched.status == .ok, let job = launched.job else {
            print("[ INIT  ] ProcessServer refused Shell.elf status=", terminator: "")
            print(launched.status.rawValue)
            return nil
        }

        UserBootPresentation.ready("[ INIT  ] Shell.elf reached Ready")
        UserBootPresentation.milestone(.session)
        return job
    }

    if processServerEndpoint != nil, shellJob == nil {
        print("[ INIT  ] no foreground session was committed")
    }

    if let diagnostic { _ = capDrop(diagnostic) }
    if let shellMachine { _ = capDrop(shellMachine) }
    if let programs { _ = capDrop(programs) }

    if let shellJob {
        superviseSession(
            on     : sessionEndpoint,
            shell  : shellJob,
            machine: machine
        )
        _ = capDrop(shellJob)
    }

    if let warden, let filesPid {
        awaitFileSystem(pid: filesPid, warden: warden)
    }

    while true {
        sleep(for: .seconds(1))
    }
}


/// Owns the effects that end the foreground session.
///
/// Shell receives only its private bootstrap endpoint and a filesystem view
/// without `unmount`. Init keeps both authorities, validates the request, marks
/// the volume clean first, acknowledges the caller, and only then asks firmware
/// to stop the machine. A malformed request changes nothing.
private func superviseSession(
    on endpoint: UInt32,
    shell job  : UInt32,
    machine    : UInt32?
) {
    while true {
        let state = jobStatus(job).state
        guard state == .configuring || state == .running else { return }

        guard var request = receive(handle: endpoint, timeout: 10) else {
            continue
        }

        guard request.message.tag.label == SessionControlOperation.shutdown.rawValue,
              request.message.tag.length == 0,
              request.grantedCap == nil
        else {
            if let stray = request.takeGrant() { _ = capDrop(stray) }
            _ = reply(message: SessionControlStatus.malformed.response)
            continue
        }

        guard capExists(BootCap.power.rawValue) else {
            _ = reply(message: SessionControlStatus.unavailable.response)
            continue
        }

        if let machine {
            guard let files = FileSystemClient(fileSystem: machine),
                  files.unmount() == .ok
            else {
                _ = reply(message: SessionControlStatus.refused.response)
                continue
            }
        }

        _ = reply(message: SessionControlStatus.ok.response)
        _ = powerOff(authority: BootCap.power.rawValue)
    }
}


/// Cut the executable namespace out of the machine root. Failure is a normal
/// boot result for an unprovisioned disk: ProcessServer is not started and no
/// legacy TAR fallback can silently restore ambient pathname execution.
private func programDirectory(in machine: UInt32) -> UInt32? {
    guard let files = FileSystemClient(fileSystem: machine) else { return nil }

    let systemName : StaticString = "system"
    let system     = files.open(
        systemName.utf8Start,
        length: systemName.utf8CodeUnitCount
    )
    guard system.status == .ok,
          let systemFolder = system.file,
          systemFolder.kind == .folder
    else { return nil }

    let programsName : StaticString = "programs"
    let programs     = files.open(
        programsName.utf8Start,
        length: programsName.utf8CodeUnitCount,
        in    : systemFolder.object
    )
    guard programs.status == .ok,
          let directory = programs.file,
          directory.kind == .folder
    else { return nil }

    return files.bind(directory.object, rights: .reader)
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
    _ = capDrop(child.handle)

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


// MARK: - Copy-on-write

/// The byte a shared page carries into a split, and must still carry after the
/// other side has written all over its own copy.
/// Frames the budgeted child below is allowed to hold.
///
/// Small enough that a handful of one-page maps reaches it, and large enough
/// that its address space fits: the root table is charged at creation and the
/// first map pays for the three levels of the walk under it. Every frame is
/// given back by `taskAbort`, so the check's transient cost is these eight
/// frames plus the task's own bookkeeping, about 32 KiB, held for as long as
/// the loop runs.
private let budgetChildFrames: UInt32 = 8


/// A child given a tiny frame budget is refused the page past it, and this
/// process carries on.
///
/// Through the task path and not through `split`, because a split child
/// inherits its parent's ceiling whole: `taskCreate` is the one call on this
/// machine that describes a child's limit, and this is the only check that the
/// number reaches the kernel at all.
///
/// The task is never started. What is under test is the charge, and the charge
/// is taken by the mapping and not by the running: a task map is the one path
/// that commits frames to a process that has not run.
private func frameBudgetSelfCheck() {

    let created = taskCreate(frameLimit: budgetChildFrames)

    guard created.succeeded else {
        print("[ CHECK ] budget: this process may not create a task")
        return
    }

    defer {
        _ = taskAbort(created.task)
        _ = capDrop(created.bootstrap)
    }

    var mapped  = 0
    var refused = false

    // One page at a time, and bounded well past the ceiling so a budget that
    // was never enforced ends the loop instead of the machine.
    for index in 0..<(Int(budgetChildFrames) + 8) {
        let result = taskMapAnonymous(
            created.task,
            at   : TaskABI.programBase + UInt64(index) * TaskABI.pageSize,
            pages: 1
        )

        if result == .outOfMemory {
            refused = true
            break
        }

        guard result == .ok else {
            print("[ CHECK ] budget: a map failed for a reason that is not the budget")
            return
        }

        mapped += 1
    }

    guard refused else {
        print("[ CHECK ] budget: the child was never refused")
        return
    }

    // Through `printDec` and not interpolation: one interpolated line pulls
    // 17 KiB of native String machinery into this image, for two numbers.
    print("[ CHECK ] budget: a child held ", terminator: "")
    printDec(UInt64(mapped), terminator: "")
    print(" of ", terminator: "")
    printDec(UInt64(budgetChildFrames), terminator: "")
    print(" frames and was refused the next")
}


private let cowPattern: UInt8 = 0xC0

/// Copy-on-write, proved by two processes sharing one page for real.
///
/// It lives in init and not in `StorageCheck` for one reason: `split` refuses
/// any process that has a parent, and init is the only process on the machine
/// that has none. Everything `StorageCheck` runs as is spawned by init, so a
/// split from there answers `UInt64.max` before it does anything at all. The
/// alternative would be relaxing that guard, which is a change to what `split`
/// means and not to whether copy-on-write is correct.
///
/// Runs under `if let machine`, so it costs nothing on a machine that mounted no
/// disk and it lands in exactly the rows `StorageCheck` already lands in.
///
/// Single writer throughout: the child prints nothing and answers with its exit
/// code, and the parent is parked in `reapChild` for as long as the child runs.
private func copyOnWriteSelfCheck() {

    // Its own region rather than the heap's: moving the break behind
    // `SbrkBackend` leaves it refusing every page it is asked for afterwards.
    let base = mmap(size: 4096)

    guard base != 0,
          let page = UnsafeMutableRawPointer(bitPattern: UInt(base))
    else {
        print("[ CHECK ] cow: no page to share")
        return
    }

    // Every road out of here gives the page back. Init outlives the machine, so
    // a frame it stops using and keeps is a frame gone for the boot.
    defer { _ = munmap(addr: base, size: 4096) }

    let bytes = page.assumingMemoryBound(to: UInt8.self)

    // Written before the split, so the page is resident and private, which is
    // the only state the clone can turn into a shared one.
    for index in 0..<4096 { bytes[index] = cowPattern }

    guard divergedAcrossSplit(bytes) else { return }

    nonExecutableDataPage(page)
}


/// The child writes over the shared page, and this side must not see it.
///
/// Then the write this side takes once the child is gone, which is the
/// promotion: the frame is back to one holder, so the descriptor regains its
/// write bit in place and no copy is taken. It has to return, and that is the
/// assertion. An unresolvable fault here would restart the same store forever
/// and this function would simply never come back.
private func divergedAcrossSplit(_ bytes: UnsafeMutablePointer<UInt8>) -> Bool {

    let pid = split()

    if pid == 0 {
        bytes[0]    = 0x0C
        bytes[4095] = 0x0C
        exit(code: 41)
    }

    guard pid != UInt64.max else {
        print("[ CHECK ] cow: this process may not split")
        return false
    }

    guard reapChild(for: pid) == 41 else {
        print("[ CHECK ] cow: the child did not finish its write")
        return false
    }

    guard bytes[0] == cowPattern, bytes[4095] == cowPattern else {
        print("[ CHECK ] cow: the child's write reached this page")
        return false
    }

    print("[ CHECK ] cow: a child's write left this page untouched")

    bytes[0] = 0x1C

    guard bytes[0] == 0x1C else {
        print("[ CHECK ] cow: the promoted page did not take the write")
        return false
    }

    print("[ CHECK ] cow: writing again after the child is gone returns")

    return true
}


/// A child points the program counter at a page of data and has to die of it.
///
/// The page is read/write and never executable, so the fetch raises a
/// permission fault on a descriptor that copy-on-write could otherwise be asked
/// to resolve. It is not resolvable by anything: no frame makes a non-executable
/// page executable. Treating it as a write fault returned the child to the same
/// instruction for as long as it was scheduled.
///
/// The kernel's own line carries the classification that decides this, and the
/// boot matrix requires it: `access=fetch`.
///
/// Two writers reach the port around this check, and around no other line this
/// process prints: the kernel reports the fault itself, on a road that owes
/// nothing to the console server everything else here travels through. Neither
/// can be ordered against the other, and a line of one arriving inside a line
/// of the other is a marker nothing can match. So each wait below empties one
/// road before the other is used.
private func nonExecutableDataPage(_ page: UnsafeMutableRawPointer) {

    // Drain what this process has already printed, so the kernel's line lands
    // between two lines instead of inside one.
    sleep(for: .milliseconds(200))

    let pid = split()

    if pid == 0 {
        let thunk = unsafeBitCast(page, to: (@convention(c) () -> Void).self)
        thunk()

        // Reached only if the fetch was allowed, which is the failure.
        exit(code: 42)
    }

    guard pid != UInt64.max else {
        print("[ CHECK ] cow: this process may not split")
        return
    }

    // Zero is every death that is not `exit(code:)`, and the only other way out
    // of that child is the 42 above.
    let code = reapChild(for: pid)

    // And now the other way round: let the kernel's line reach the port before
    // the verdict below enters the console server's queue.
    sleep(for: .milliseconds(200))

    guard code == 0 else {
        print("[ CHECK ] cow: a jump into a data page was executed")
        return
    }

    print("[ CHECK ] cow: a jump into a data page killed the child alone")
}
