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
    
    print("Hi, this is child process!")

    if spawnService() == nil {
        print("Child: Eunuch [OK]")
        
    } else {
        print("Child: Not Eunuch [FAIL]")
    }


    guard let parentHandle = parentEndpoint() else {
        print("Child has no parent endpoint!")
        exit(code: 1)
    }
    
    
    let received = receive(handle: parentHandle)
    if let serverCap = received.grantedCap {
        var dataWords = InlineArray<4, UInt32>(repeating: 0)
        dataWords[0] = 67
        _ = send(
            handle : serverCap,
            message: Message(tag: MessageTag(TestIPCLabel.open, length: 1), words: dataWords)
        )
    }
    
    
    while true { yield() }

//    exit(code: 0)
}
