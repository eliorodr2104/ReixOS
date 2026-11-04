//
//  FileSystemServerMain.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Reix

@_cdecl("_start")
public func main() {
    ServiceRuntime.run(FileSystemServer.self)
}
