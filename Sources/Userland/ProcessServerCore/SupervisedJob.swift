//
//  SupervisedJob.swift
//  ReixOS
//

/// Keeps the job handle with the child to reap once that handle reports exit.
struct SupervisedJob {
    let handle: UInt32
    let pid   : UInt64
}
