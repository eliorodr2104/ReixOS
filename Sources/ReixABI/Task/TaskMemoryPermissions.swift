//
//  TaskMemoryPermissions.swift
//  ReixOS
//

public struct TaskMemoryPermissions: OptionSet {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let read    = TaskMemoryPermissions(rawValue: 1 << 0)
    public static let write   = TaskMemoryPermissions(rawValue: 1 << 1)
    public static let execute = TaskMemoryPermissions(rawValue: 1 << 2)

    public static let known: TaskMemoryPermissions = [.read, .write, .execute]
}
