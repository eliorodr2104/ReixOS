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
    

    let serverProcess = spawnProcess(path: "ServerProcess.elf")
    let firstChild    = spawnProcess(path: "Child.elf")
    

    var dataWords = InlineArray<4, UInt32>(repeating: 0)
    dataWords[0] = 67
    _ = send(
        handle : firstChild.handle,
        message: Message(tag: MessageTag(TestIPCLabel.open, length: 1), words: dataWords),
        grant  : serverProcess.handle
    )
    
    while true { yield() }

//    exit(code: 0)
}
