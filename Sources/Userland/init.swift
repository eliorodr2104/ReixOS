//
//  init.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

import Reix

enum TestIPCLabel: UInt32, IPCLabel {
    case open = 0
}

@_cdecl("_start")
public func main() {
    
    let processCount = 1000
    var pidsChildren: InlineArray<1000, PID> = InlineArray(repeating: 0)
    for i in 0..<processCount {
        let pid = split()
                
        if pid == 0 {
            for _ in 0..<670 {
                yield()
            }
            
            
            exit(code: 0)
        }
        
        pidsChildren[i] = pid
    }
    
    // Need create a reap childrens syscall, this reap all childrens
    
    for i in 0..<processCount {
        _ = reapChild(for: pidsChildren[i])
    }
    
    print("End Stress Operation")
    
    exit(code: 0)
    
//    print("Hi, this is init process!")
//
//    let spawn = spawnProcess(path: "child.elf")

//    if childPid == 0 {
//        let receivedMessage = receive(handle: firstEndpoint)
//        
//        guard let secondEndpointCapability = receivedMessage.grantedCap else {
//            print("Not received capability!")
//            exit(code: 1)
//        }
//        
//        print("Received Capability, new handle:", terminator: " ")
//        print(String(secondEndpointCapability))
//
//        let data = receive(handle: secondEndpointCapability)
//        print("Data on secondEndpoint:", terminator: " ")
//        print(String(UInt64(data.message.words[0])))
//        
//        exit(code: 0)
//    }

//    var dataWords = InlineArray<4, UInt32>(repeating: 0)
//    dataWords[0] = 67
//    _ = send(
//        handle : spawn.handle,
//        message: Message(tag: MessageTag(TestIPCLabel.open, length: 1), words: dataWords)
//    )
//
//    exit(code: 0)
}
