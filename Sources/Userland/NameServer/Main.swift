//
//  Main.swift
//  ReixOS
//
//  Created by Eliomar on 08/06/2026.
//

import Reix

@_cdecl("_start")
public func main() {
    
    var server = NameServer()
    
    server.run()
    
    while true { yield() }
}
