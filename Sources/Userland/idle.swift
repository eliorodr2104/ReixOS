//
//  idle.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/05/2026.
//

import Reix

@_cdecl("_start")
public func main() {
    
    print(String(getPID()))
    print("Idle process")
    
    while true {  }
}
