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
    let endpointHandle = spawnEndpoint()
    
    
    print("Splitting myself...\n")
    let resultSplit = split()
    
    
    if resultSplit == 0 {
        print("I'm children server!")
        print("Respond message to my parent!\n")
        var request = receive(handle: endpointHandle)
        while true {
            var words = InlineArray<4, UInt32>(repeating: 0)
            words[0] = request.words[0] + 1
            
            request = replyRecv(
                handle: endpointHandle,
                message: Message(tag: request.tag, words: words)
            )
        }
        
        exit(code: 0)
    }
    
    print("Call Children Server...")
    var words = InlineArray<4, UInt32>(repeating: 0)
    print("Send 90 Message:", terminator: " ")
    print(String(words[0]))
    print("")
    
    
    for i in 0..<99999 {
        words[0] = UInt32(66 + i)
        let resp = call(
            handle: endpointHandle,
            message: Message(
                tag: MessageTag(TestIPCLabel.open, length: 1),
                words: words
            )
        )
    }
    
    print("End Sending messages")
//    print("[PARENT] Message Received:", terminator: " ")
//    print(String(resp.words[0]))
//    print("")

    exit(code: 0)
}
