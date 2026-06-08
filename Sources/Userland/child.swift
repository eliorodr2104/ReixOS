//
//  child.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

import Reix

enum TestIPCLabel: UInt32, IPCLabel {
    case open = 0
}

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

    
    let request = call(handle: nsCap, message: NameServerOperation.lookup.message(for: .fileSystem))
    
    if request.grantedCap != nil {
        print("[ CHILD ] lookup OK, Have key dummy server")
    }
        
    
    while true { yield() }
}
