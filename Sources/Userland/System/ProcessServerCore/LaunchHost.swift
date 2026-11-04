//
//  LaunchHost.swift
//  ReixOS
//

import ReixABI

/// The effects of a launch, kept outside the policy so a host can rehearse every exit.
public protocol LaunchHost {
    associatedtype File: ProgramFile

    /// The authority a profile requires, or nothing when it cannot be supplied.
    func handle(for binding: EnvironmentBinding) -> UInt32?
    /// Opens the exact program basename, before its bytes are claimed.
    mutating func openProgram(_ name: InlineArray<12, UInt8>, length: Int) throws(ProcessServerStatus) -> File
    /// Returns the configuring task and its private bootstrap endpoint together.
    mutating func createTask(_ name: InlineArray<12, UInt8>, length: Int) -> (task: UInt32, bootstrap: UInt32)?
    /// Gives the configuring task anonymous pages for a planned region.
    mutating func map(_ task: UInt32, at address: UInt64, pages: UInt32) -> Bool
    /// Copies one chunk into the configuring task while the file is claimed.
    mutating func write(_ task: UInt32, at address: UInt64, bytes: UnsafeRawPointer, count: Int) -> Bool
    /// Fixes a region's permissions after its last write.
    mutating func seal(_ task: UInt32, at address: UInt64, pages: UInt32, permissions: TaskMemoryPermissions) -> Bool
    /// Sets the complete initial context before starting the task.
    mutating func setContext(_ task: UInt32, entry: UInt64, stack: UInt64, programBreak: UInt64) -> Bool
    /// Starts the task, turning its handle into a job, and returns its pid.
    mutating func start(_ task: UInt32) -> UInt64?
    /// Discards a configuring task, which leaves no corpse to reap.
    mutating func abort(_ task: UInt32)
    /// Asks a started job to stop without promising that it has exited.
    mutating func cancel(_ job: UInt32)
    /// Reads the state that decides whether a job is safe to reap.
    func state(of job: UInt32) -> TaskState
    /// Reaps a child only after its job was observed exited.
    mutating func reap(_ pid: UInt64)
    /// Lets go of one handle the server still holds.
    mutating func drop(_ handle: UInt32)
    /// Offers one bootstrap message without waiting for a receiver.
    mutating func trySend(_ endpoint: UInt32, _ message: Message, grant: UInt32?, rights: CapRights) -> IPCStatus
    /// Takes one bootstrap message without waiting for a sender.
    mutating func tryReceive(_ endpoint: UInt32) -> (message: Message, grant: UInt32?)?
    /// Checks a requester's identity at admission or at a periodic reclaim.
    func alive(_ identity: UInt32) -> Bool
    /// Answers the particular held call, with a restricted job grant on success.
    mutating func reply(_ status: ProcessServerStatus, to identity: UInt32, job: UInt32?) -> Bool
    /// Says why an autonomous reclaim happened before the requester is answered.
    mutating func reclaimed(_ cause: LaunchReclaim)
}
