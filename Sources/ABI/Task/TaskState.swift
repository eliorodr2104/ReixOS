//
//  TaskState.swift
//  ReixOS
//

public enum TaskState: UInt64 {
    case invalid     = 0
    case configuring = 1
    case running     = 2
    case exited      = 3
    case aborted     = 4
}
