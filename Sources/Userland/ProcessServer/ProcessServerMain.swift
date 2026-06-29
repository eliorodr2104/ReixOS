//
//  Main.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/05/2026.
//

import Reix

@_cdecl("_start")
public func main() {
    ServiceRuntime.run(ProcessServer.self)
}
