//
//  ServerProcess.swift
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
    
    print("Hi, ServerProcess is running!")
          
    guard let parentHandle = parentEndpoint() else {
        print("Child has no parent endpoint!")
        exit(code: 1)
    }
    
    while true {
        let req = receive(
            handle : parentHandle
        )
        
        if req.message.words[0] == 67 {
            print("Message arrived")
        }
    }
                    
    
    
    print("Receive: ", terminator: " ")
//    print(String(req.message.words[0]))
}
