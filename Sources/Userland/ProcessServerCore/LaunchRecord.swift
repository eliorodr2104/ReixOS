//
//  LaunchRecord.swift
//  ReixOS
//

/// Keeps an accepted call and what it holds together until it is answered or reclaimed.
struct LaunchRecord {
    let requester : UInt32
    let deadline  : LaunchDeadline
    let profile   : ProgramProfile
    let name      : InlineArray<12, UInt8>
    let nameLength: Int
    let nonce     : UInt32
    let rehearsal : LaunchRehearsal
    var state     : LaunchState = .queued
    var task      : UInt32? = nil   // task handle, then the job handle in the same slot after start
    var bootstrap : UInt32? = nil
    var pid       : UInt64 = 0
}
