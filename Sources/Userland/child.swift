//
//  child.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

import Reix

@_cdecl("_start")
public func main() {
    
    print("[ CHILD ] Hi, this is child process!\n")
    
    if spawnService() == nil {
        print("[ CHILD ] Is Eunuch")
        
    } else {
        print("[ CHILD ] Have balls")
    }


    guard let parentHandle = parentEndpoint() else {
        print("[ CHILD ] Don't have parent endpoint!")
        exit(code: 1)
    }
    
    
    let received = receive(handle: parentHandle)
    guard let nsCap = received.grantedCap else {
        print("[ CHILD ] no NS cap")
        exit(code: 1)
    }

    // API ergonomica: niente piu call/message a mano.
    let nameServer = NameServerClient(endpoint: nsCap)

    guard let processServer = ProcessServerClient(via: nameServer) else {
        print("[ CHILD ] no process server")
        exit(code: 1)
    }
    print("[ CHILD ] lookup OK, Have process server key")

    if let spawned = processServer.spawn(.child2) {
        print("[ CHILD ] Child Pid: ", terminator: " ")
        print(String(spawned.pid))
    }

    while true { yield() }
}
