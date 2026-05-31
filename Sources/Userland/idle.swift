//
//  idle.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/05/2026.
//

import Reix

@_cdecl("_start")
public func main() {
    
    print("Idle process")
    
    print("Wait message IPC\n")
    let msg = receive(handle: 0)
    
    print("Receive message!")
    print(String(UInt64(msg.words[0]))) // Need print 42
    
    while true { yield() }
}
