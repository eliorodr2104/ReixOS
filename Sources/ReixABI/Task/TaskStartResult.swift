//
//  TaskStartResult.swift
//  ReixOS
//

public struct TaskStartResult {
    public let result: TaskResult
    public let pid   : UInt64

    public init(
        result: TaskResult,
        pid   : UInt64
    ) {
        self.result = result
        self.pid = pid
    }
}
