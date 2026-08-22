//
//  ProcessStatusLabel.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// How a scheduler state reads on a screen.
///
/// In the SDK and not in a tool, because it is the rendering of an ABI enum and
/// two readers want it now. A private copy in each was how the process fixtures
/// drifted apart, and the header of that file says so.
public extension ProcessStatusCode {

    var label: StaticString {
        switch self {
            case .new             : "New"
            case .ready           : "Ready"
            case .running         : "Running"
            case .waiting         : "Waiting"
            case .blockedOnSend   : "Blocked on Send"
            case .blockedOnReceive: "Blocked on Receive"
            case .blockedOnReply  : "Blocked on Reply"
            case .terminated      : "Terminated"
        }
    }
}
