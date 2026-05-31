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
    
    print("Send message to idle process!\n")
    var words = InlineArray<4, UInt32>(repeating: 0)
    words[0] = 42
    let msg = Message(
        tag  : MessageTag(TestIPCLabel.open, length: 1),
        words: words
    )
    _ = send(handle: 0, message: msg)
    
    exit(code: 0)
}
