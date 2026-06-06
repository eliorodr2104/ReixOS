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
    
    let parentMessage = receive(
        handle : parentHandle
    )
    
    if parentMessage.message.words[0] == 67 {
        print("Message arrived")
    }
    
    let child = spawnProcess(path: "Child.elf")
    
    var dataWords = InlineArray<4, UInt32>(repeating: 0)
    dataWords[0] = 67
    _ = send(
        handle : child.handle,
        message: Message(tag: MessageTag(TestIPCLabel.open, length: 1), words: dataWords)
    )
    
    
    while true {
        let _ = receive(
            handle : parentHandle
        )
        
    }
}
