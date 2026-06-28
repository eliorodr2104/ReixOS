//
//  SchedulerError.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/05/2026.
//

public enum SchedulerError: KernelDiagnostic {
    case notNewerProcess
    case processNotExist

    public var description: String {
        switch self {
            case .notNewerProcess: "Scheduler Error: the process is not in the .new state."
            case .processNotExist: "Scheduler Error: the PID is not in any scheduler queue."
        }
    }

    public var category: ErrorCategory { .scheduler }
}
