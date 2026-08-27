//
//  FSFound.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

import ReixABI

/// An object number, or the refusal instead of one.
///
/// The same reasoning as `FSRun`, for the two places this file system answers
/// with an object: taking a free slot in the table, and resolving a name in a
/// folder. Both used to answer `nil`, and both had several reasons to.
///
/// The lookup is the one that mattered. "There is no such name" is what
/// authorises writing one, so a folder whose directory block would not read used
/// to authorise a second entry with a name the folder already had. Here the miss
/// is `refused(.notFound)` and the unreadable folder is `refused(.deviceFailed)`,
/// and no caller can confuse them by accident.
public enum FSFound {

    case at(UInt32)

    case refused(FSStatus)

    /// Why there is no object. `ok` when there is one.
    public var refusal: FSStatus {
        switch self {
            case .at               : return .ok
            case .refused(let why) : return why
        }
    }

    /// The object, for a caller that has already dealt with the refusal or has
    /// nothing to do with it.
    public var object: UInt32? {
        guard case .at(let index) = self else { return nil }
        return index
    }
}
