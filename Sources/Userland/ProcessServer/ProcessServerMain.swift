//
//  ProcessServerMain.swift
//  ReixOS
//

import Reix

@_cdecl("_start")
public func main() {
    ServiceRuntime.run(ProcessServer.self)
}
