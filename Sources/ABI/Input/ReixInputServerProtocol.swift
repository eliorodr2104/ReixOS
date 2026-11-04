//
//  ReixInputServerProtocol.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

/// Labels understood by InputServer. A capability badge selects the role.
public enum ReixInputServerOperation: UInt32, IPCLabel {
    case registerSourceRing = 1
    case registerSourceCallback = 2
    case registerConsumer = 3
    case pull = 4
    case focus = 5
    case status = 6
}

public enum ReixInputServerStatus: UInt32, Equatable {
    case ok = 0
    case refused = 1
    case full = 2
    case empty = 3
    case malformed = 4
    case stale = 5
    case pending = 6
    case timedOut = 7
}

/// The one callback an InputServer invokes on a registered source.
public enum ReixInputSourceOperation: UInt32, IPCLabel {
    case produce = 5
}

public enum ReixInputSourceStatus: UInt32, Equatable {
    case ok = 0
    case empty = 1
    case timedOut = 2
    case stale = 3
    case refused = 4
}
