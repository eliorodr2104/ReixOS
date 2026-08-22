//
//  main.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import Reix

@_cdecl("_start")
public func main() {
    ServiceRuntime.run(TerminalServer.self)
}
