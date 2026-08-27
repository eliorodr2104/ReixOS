//
//  FSSuperblockField.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

/// Where each field of a superblock lives.
///
/// Outside `FileSystem` because that type is generic over its device, and a
/// generic type may hold no stored constants. Which is just as well: these are
/// facts about the format and not about any one mount of it.
enum FSSuperblockField {
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

    /// Which of the two copies is the newer one. Bumped on every write of
    /// either, so the two are never in doubt.
    static let generation   = 72

    static let journalStart  = 80
    static let journalBlocks = 84

    /// Written last of the fields, and the cheap half of "this block is a whole
    /// superblock". The checksum is the half that actually detects a torn write.
    static let commit        = 88

    /// Over every byte above, with these four read as zero.
    static let checksum      = 92

    /// How much of the block a superblock uses. Everything after is zero.
    static let width         = 96
}
