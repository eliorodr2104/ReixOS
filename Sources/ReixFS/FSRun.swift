//
//  FSRun.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

import ReixABI

/// A run of blocks that was claimed, or the refusal instead of it.
///
/// This is not an `Optional`, and the difference is the whole point of the type.
/// `nil` said no for four different reasons - the disk is full, the disk stopped
/// answering, the volume is held still, the journal has no room for another
/// image - and the caller could only report the first of them. Every one of the
/// other three was a `noSpace` sent to a client whose disk had actually gone
/// away, and a caller that then went looking for space it would never find.
///
/// `refusal` is what a `guard` reads on the way out. It cannot be mistaken for a
/// success, because the branch that reads it is the branch where there is no run.
enum FSRun {

    case taken(start: UInt32, count: UInt32)

    case refused(FSStatus)

    /// Why there is no run. `ok` when there is one.
    var refusal: FSStatus {
        switch self {
            case .taken            : return .ok
            case .refused(let why) : return why
        }
    }
}
