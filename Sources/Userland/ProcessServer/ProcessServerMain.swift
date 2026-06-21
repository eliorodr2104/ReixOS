//
//  Main.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/05/2026.
//

import Reix

@_cdecl("_start")
public func main() {

    var server = ProcessServer()
    server.run()

    while true { yield() }
}
