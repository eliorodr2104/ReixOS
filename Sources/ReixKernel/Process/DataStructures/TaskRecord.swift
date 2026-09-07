//
//  TaskRecord.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

struct TaskRecord {
    let control             : TaskControl
    let owner               : Identity
    var process             : UnsafeMutablePointer<Process>?
    var lifecycle           : TaskLifecycle
    var regions             : InlineArray<32, TaskRegion?>
    var regionCount         : UInt8
    var contextSet          : Bool
    var capabilityReferences: UInt16

    init(
        control: TaskControl,
        owner  : Identity,
        process: UnsafeMutablePointer<Process>
    ) {
        self.control = control
        self.owner = owner
        self.process = process
        self.lifecycle = .configuring
        self.regions = InlineArray<32, TaskRegion?>(repeating: nil)
        self.regionCount = 0
        self.contextSet = false
        self.capabilityReferences = 0
    }
}
