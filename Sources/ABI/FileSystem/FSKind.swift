//
//  FSKind.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

/// What an object is.
///
/// A kind and not a bit in a mode word. Whether something may be opened, read
/// or written is decided by the capability that reached it, so the only thing
/// left for the object itself to say is what shape it has.
public enum FSKind: UInt8 {

    /// A slot in the table nobody is using.
    case free = 0

    /// Bytes.
    case file = 1

    /// Names pointing at other objects.
    case folder = 2

    /// A folder that is also the root of somebody's world. Slice C gives these
    /// their meaning; the format carries the distinction from the start so that
    /// giving it meaning is not a reformat.
    case container = 3
}
