//
//  TaskResult.swift
//  ReixOS
//

public enum TaskResult: UInt64 {
    case ok                 = 0
    case invalidCapability  = 1
    case invalidState       = 2
    case invalidRange       = 3
    case permissionConflict = 4
    case outOfMemory        = 5
    case full               = 6
    case malformed          = 7
}
