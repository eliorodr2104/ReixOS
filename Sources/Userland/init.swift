//
//  init.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

import RXTask
import RXIO

@_cdecl("_start")
public func main() {
        
    print(String(getPID()))
    print("Hi, this is init process!")
}
