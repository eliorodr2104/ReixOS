//
//  ConsoleServerMain.swift
//  ReixOS
//
//  Created by Eliomar on 29/06/2026.
//

import Reix

@_cdecl("_start")
public func main() {
    ServiceRuntime.run(ConsoleServer.self)
}
