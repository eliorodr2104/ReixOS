//
//  TaskStatus.swift
//  ReixOS
//

public struct TaskStatus {
    public let state   : TaskState
    public let exitCode: ExitCode

    public init(
        state   : TaskState,
        exitCode: ExitCode
    ) {
        self.state = state
        self.exitCode = exitCode
    }
}
