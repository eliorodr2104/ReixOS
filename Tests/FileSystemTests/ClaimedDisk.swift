//
//  ClaimedDisk.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.

import Testing
import ReixABI
@testable import ReixFS

/// A device that declares a geometry and stores nothing.
///
/// It exists for the numbers only: a real disk cannot be asked to claim thirty-six
/// thousand million million sectors without allocating them, and that claim is
/// exactly the one the arithmetic has to survive. Every transfer refuses,
/// because nothing here is ever meant to be read.
struct ClaimedDisk: BlockDevice {

    let sectorSize : UInt64
    let sectorCount: UInt64
    let maximumRun : UInt64 = 8
    let durability : BlockDurability = .onFlush

    var depth: Int { 1 }

    func begin(_ count: UInt64, from sector: UInt64, slot: Int) -> BlockStatus {
        .deviceRefused
    }

    func collect() -> (slot: Int, status: BlockStatus)? { nil }

    func buffer(of slot: Int) -> UnsafeRawPointer {
        UnsafeRawPointer(bitPattern: 0x1000)!
    }

    func read(
        _ count: UInt64,
        from sector: UInt64,
        into destination: UnsafeMutableRawPointer
    ) -> BlockStatus { .deviceRefused }

    func write(
        _ count: UInt64,
        to sector: UInt64,
        from source: UnsafeRawPointer
    ) -> BlockStatus { .deviceRefused }

    func flush() -> BlockStatus { .deviceRefused }
}
