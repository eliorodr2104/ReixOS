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
            rights: [.grant]
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

    let nameServer = spawnProcess(path: "NameServer.elf")
    guard let nameServerEndpoint = receive(
        handle: nameServer.handle
    ).grantedCap else { return }

    guard let spawnCap = spawnService() else { return }

    let environment = Environment(
        console   : consoleEndpoint,
        nameServer: nameServerEndpoint,
        spawn     : spawnCap
    )

    _ = launch("ProcessServer.elf", environment: environment)

    while true { yield() }
}
