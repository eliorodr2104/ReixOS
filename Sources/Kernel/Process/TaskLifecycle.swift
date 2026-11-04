//
//  TaskLifecycle.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// Where a task stands. The construction object rides the `configuring` case,
/// so a task holds one exactly while it can still be configured, and no other
/// state can name a construction that was already given back.
enum TaskLifecycle {
    case configuring(UnsafeMutablePointer<TaskConstruction>)
    case running
    case exited(ExitCode)
    case aborted
}
