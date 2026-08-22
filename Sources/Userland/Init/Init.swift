//
//  init.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.

import Reix

@_cdecl("_start")
public func main() {

    print("[ INIT  ] Hi, this is init process!\n")

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
        session: NameServerSession.registrar,
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

    _ = launch(
        "ProcessServer.elf",
        environment: environment,
        registrar  : registrar
    )

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


    while true {
        sleep(for: .seconds(1))
    }
}
