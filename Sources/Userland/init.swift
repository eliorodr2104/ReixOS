//
//  init.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

import Reix

@_cdecl("_start")
public func main() {
    
    print("[ INIT  ] Hi, this is init process!\n")
    print("[ INIT  ] Launching Name Server")
    
    let nameServer = spawnProcess(path: "NameServer.elf")
    let capPublic  = receive(handle: nameServer.handle)
    
    guard let nsCapability = capPublic.grantedCap else {
        return
    }
    
    
    let processServer = spawnProcess(path: "ProcessServer.elf")
    _ = send(
        handle     : processServer.handle,
        message    : NameServerResponse.ok.message,
        grant      : spawnService(),
        grantRights: [.spawn, .grant]
    )

    _ = send(
        handle     : processServer.handle,
        message    : NameServerResponse.ok.message,
        grant      : nsCapability,
        grantRights: [.send, .grant, .derive]
    )
    
    while true { yield() }

//    exit(code: 0)
}
