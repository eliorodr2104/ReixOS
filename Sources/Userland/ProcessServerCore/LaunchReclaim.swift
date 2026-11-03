//
//  LaunchReclaim.swift
//  ReixOS
//

/// Why the server gave a launch up on its own, said before anything is answered.
public enum LaunchReclaim: Equatable {
    case deadline, requesterGone, programDied
}
