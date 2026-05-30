//
//  idle.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/05/2026.
//

import Reix

@_cdecl("_start")
public func main() {
    
    
    let currentPid = getPID()
    print("Test a reap self process")
    let result = reapChild(for: currentPid)
    
    print(String(result))
    print("Idle process")
    
    while true { yield() }
}
