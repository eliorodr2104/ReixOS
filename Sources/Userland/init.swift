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
    print("Hi, this is init process!")

    let firstEndpoint = spawnEndpoint()
    let childPid = split()

    if childPid == 0 {
        let receivedMessage = receive(handle: firstEndpoint)
        
        guard let secondEndpointCapability = receivedMessage.grantedCap else {
            print("Not received capability!")
            exit(code: 1)
        }
        
        print("Received Capability, new handle:", terminator: " ")
        print(String(secondEndpointCapability))

        let data = receive(handle: secondEndpointCapability)
        print("Data on secondEndpoint:", terminator: " ")
        print(String(UInt64(data.message.words[0])))
        
        exit(code: 0)
    }

    
    let secondEndpoint = spawnEndpoint()

    let emptyWords = InlineArray<4, UInt32>(repeating: 0)
    _ = send(
        handle : firstEndpoint,
        message: Message(tag: MessageTag(TestIPCLabel.open, length: 0), words: emptyWords),
        grant  : secondEndpoint
    )

    var dataWords = InlineArray<4, UInt32>(repeating: 0)
    dataWords[0] = 99
    _ = send(
        handle : secondEndpoint,
        message: Message(tag: MessageTag(TestIPCLabel.open, length: 1), words: dataWords)
    )

    exit(code: 0)
}
