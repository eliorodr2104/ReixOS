//
//  TaskCreation.swift
//  ReixOS
//

public struct TaskCreation {
    public let task     : UInt32
    public let bootstrap: UInt32

    public init(
        task     : UInt32,
        bootstrap: UInt32
    ) {
        self.task = task
        self.bootstrap = bootstrap
    }

    public var succeeded: Bool {
        task != UInt32.max && bootstrap != UInt32.max
    }
}
