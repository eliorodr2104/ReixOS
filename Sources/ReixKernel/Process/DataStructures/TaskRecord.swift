//
//  TaskRecord.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// What the registry keeps of a task for its whole life: who owns it, the
/// process while there is one, where it stands, and how many capabilities
/// still name it.
///
/// Everything a task needs only while it is being built lives in the
/// `TaskConstruction` its `configuring` state points at, so a task that has
/// started or ended costs 32 bytes and not the region table it no longer reads.
/// The slot and generation are the registry's and not the record's: the index
/// is the slot, and `TaskRegistry.generations` outlives the record on purpose.
struct TaskRecord {
    let owner               : Identity                        // 4 Byte
    var capabilityReferences: UInt16                          // 2 Byte
    var process             : UnsafeMutablePointer<Process>?  // 8 Byte
    var lifecycle           : TaskLifecycle                   // 9 Byte

    init(
        owner       : Identity,
        process     : UnsafeMutablePointer<Process>,
        construction: UnsafeMutablePointer<TaskConstruction>
    ) {
        self.owner                = owner
        self.capabilityReferences = 0
        self.process              = process
        self.lifecycle            = .configuring(construction)
    }
}
