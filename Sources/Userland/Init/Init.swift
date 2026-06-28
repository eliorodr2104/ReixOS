//
//  init.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

import Reix

@_cdecl("_start")
public func main() {
    
    print("[ INIT  ] Hi, this is init process!\n")
    print("[ INIT  ] Launching Name Server")
    
    let nameServer = spawnProcess(path: "NameServer.elf")
    let capPublic  = receive(handle: nameServer.handle)
    
    guard let nsCapability = capPublic.grantedCap else {
        return
    }
    
    
    let processServer = spawnProcess(path: "ProcessServer.elf")
    send(
        handle     : processServer.handle,
        message    : NameServerResponse.ok.message,
        grant      : spawnService(),
        grantRights: [.spawn, .grant]
    )

    send(
        handle     : processServer.handle,
        message    : NameServerResponse.ok.message,
        grant      : nsCapability,
        grantRights: [.send, .grant, .derive]
    )
    
    
    // TEST UART USERLAND
    
    guard let cap = deviceCap() else { return }
    let regs = mapDevice(handle: cap)
    
    if regs != 0, let base = UnsafeMutableRawPointer(bitPattern: UInt(regs)) {
        let fr = base + 0x18
        
        func put(_ byte: UInt8) {
            while (fr.load(as: UInt32.self) & 0x20) != 0 { }
            base.storeBytes(of: UInt32(byte), as: UInt32.self)
        }
        
        "[ INIT  ] Use the UART in userland!\n".utf8.forEach { put($0) }
    }
    
    while true { yield() }
}
