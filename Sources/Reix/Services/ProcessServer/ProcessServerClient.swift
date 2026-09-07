//
//  ProcessServerClient.swift
//  ReixOS
//

import ReixABI

public struct ProcessLaunchResult {
    public let status: ProcessServerStatus
    public let job   : UInt32?

    public init(
        status: ProcessServerStatus,
        job   : UInt32?
    ) {
        self.status = status
        self.job = job
    }
}

/// Ask ProcessServer to resolve and load one basename from its read-only
/// program directory. The request carries no pathname buffer or ambient PID;
/// success returns a job capability installed by IPC.
public func launchProgram(
    through processServer: UInt32,
    name                 : UnsafePointer<UInt8>,
    length               : Int
) -> ProcessLaunchResult {
    guard let request = ProcessLaunchRequest.message(name: name, length: length) else {
        return ProcessLaunchResult(status: .badRequest, job: nil)
    }

    guard case .success(var answer) = call(
        handle : processServer,
        message: request
    ),
    answer.message.tag.label == ProcessServerOperation.launch.rawValue,
    answer.message.tag.length >= 1,
    let status = ProcessServerStatus(rawValue: answer.message.words[0])
    else {
        return ProcessLaunchResult(status: .unavailable, job: nil)
    }

    guard status == .ok else {
        if let stray = answer.takeGrant() { _ = capDrop(stray) }
        return ProcessLaunchResult(status: status, job: nil)
    }

    guard let job = answer.takeGrant() else {
        return ProcessLaunchResult(status: .taskFailure, job: nil)
    }

    return ProcessLaunchResult(status: .ok, job: job)
}
