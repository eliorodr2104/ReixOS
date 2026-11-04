//
//  LaunchRehearsal.swift
//  ReixOS
//

/// What a diagnostic launch rehearses. A release build only ever asks for `.none`;
/// the names that select the others exist only in the diagnostic image.
public enum LaunchRehearsal: UInt8 {
    case none, withholdCommit, trapAtEntry
}
