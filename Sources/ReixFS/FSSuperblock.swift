//
//  FSSuperblock.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

/// Where each field of block zero lives.
///
/// Outside `FileSystem` because that type is generic over its device, and a
/// generic type may hold no stored constants. Which is just as well: these are
/// facts about the format and not about any one mount of it.
enum Field {
    static let magic       = 0
    static let blockSize   = 8
    static let totalBlocks = 12
    static let bitmapStart = 16
    static let bitmapCount = 20
    static let tableStart  = 24
    static let tableCount  = 28
    static let dataStart   = 32
    static let objectCount = 36
    static let rootObject  = 40
    static let state       = 44

    /// The machine's own name, as bytes, no terminator. It is a property of the
    /// disk and not of the build, so a disk carried to another machine still
    /// says what it calls itself.
    static let name        = 48
}
