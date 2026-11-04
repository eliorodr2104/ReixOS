//
//  TaskControl.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// Stable identity carried by task and job capabilities.
///
/// It is a slot plus a generation. Reaping may free the process record while
/// a job capability stays valid and reports the terminal state this registry
/// keeps.
public struct TaskControl: Equatable {
    let slot      : UInt8
    let generation: UInt32

    init(
        slot      : UInt8,
        generation: UInt32
    ) {
        self.slot = slot
        self.generation = generation
    }
}
