//
//  TaskLifecycle.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

enum TaskLifecycle {
    case configuring
    case running
    case exited(ExitCode)
    case aborted
}
