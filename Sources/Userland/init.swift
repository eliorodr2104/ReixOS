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
    
    let serverProcess = spawnProcess(path: "ProcessServer.elf")
    
    if let grantHandle = spawnService() {
        var dataWords = InlineArray<4, UInt32>(repeating: 0)
        dataWords[0] = 67
        _ = send(
            handle : serverProcess.handle,
            message: Message(tag: MessageTag(TestIPCLabel.open, length: 1), words: dataWords),
            grant      : grantHandle,
            grantRights: [.spawn, .grant]
        )
    }
    
    while true { yield() }

//    exit(code: 0)
}
