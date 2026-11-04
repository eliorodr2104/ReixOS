//
//  TaskRegion.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

struct TaskRegion {
    let start      : VirtualAddress
    let end        : VirtualAddress
    var permissions: TaskMemoryPermissions
    var sealed     : Bool
}
