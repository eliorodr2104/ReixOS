//
//  Main.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/05/2026.
//

import Reix

enum TestIPCLabel: UInt32, IPCLabel {
    case open = 0
}

@_cdecl("_start")
public func main() {
    
    print("[ SERVE ] Hi, Process Server is running!\n")
          
    guard let parentHandle = parentEndpoint() else {
        print("Child has no parent endpoint!")
        exit(code: 1)
    }
    
    
    _ = receive(handle: parentHandle)
    let bootNs = receive(handle: parentHandle)
    
    
    guard let nsCap = bootNs.grantedCap else {
        print("[ SERVE ] no NS cap")
        exit(code: 1)
    }

    print("[ SERVE ] have spawn-cap e NS-cap")
    
    if spawnService() != nil {
        print("[ SERVE ] Can Spawn process")
    }
    
    let dummyEp = spawnEndpoint()
    _ = send(
        handle     : nsCap,
        message    : NameServerOperation.register.message(for: .fileSystem),
        grant      : dummyEp,
        grantRights: [.send, .grant]
    )
    print("[ SERVE ] fileSystem register ")
    
    let child = spawnProcess(path: "Child.elf")
    guard let childNs = derive(handle: nsCap, badge: 1, rights: [.send, .grant]) else {
        print("[ SERVE ] derive failed"); exit(code: 1)
    }
    
    _ = send(
        handle     : child.handle,
        message    : NameServerResponse.ok.message,
        grant      : childNs,
        grantRights: [.send]
    )
    print("[ SERVE ] Child send grant")
    
    while true { yield() }
}
