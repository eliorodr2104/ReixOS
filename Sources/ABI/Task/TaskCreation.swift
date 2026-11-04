//
//  TaskCreation.swift
//  ReixOS
//

public struct TaskCreation {
    /// Diagnostic identity carried by task creation. Names are printable ASCII
    /// so an untrusted launcher cannot inject terminal control bytes into the
    /// process table or trace decoder. They are metadata only: the kernel never
    /// interprets them as paths, programs, or authority.
    public static let maximumNameBytes = 16

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
