//
//  ELFByteSource.swift
//  ReixOS
//

import ReixABI

/// Random-access bytes consumed by the pure ELF planner.
/// Implementations may read RxFS, a host fixture, or any other bounded source.
public protocol ELFByteSource {
    var size: UInt64 { get }

    mutating func read(
        at offset       : UInt64,
        into destination: UnsafeMutableRawPointer,
        count           : Int
    ) -> Bool
}
