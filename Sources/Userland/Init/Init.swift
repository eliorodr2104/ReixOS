//
//  init.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.

import Reix

@_cdecl("_start")
public func main() {

    print("[ INIT  ] Hi, this is init process!\n")

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

    while true { yield() }
}
