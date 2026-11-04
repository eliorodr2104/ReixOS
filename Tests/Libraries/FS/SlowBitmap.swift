//
//  SlowBitmap.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.

import Testing
import ReixABI
@testable import ReixFS

/// The bit-at-a-time block map, kept here and nowhere else.
///
/// It *was* the implementation, in `FileSystemSpace`, and it is the reference the
/// word-at-a-time one is judged against: every answer, over every pattern below,
/// has to be the same one. Keeping it is the only way a rewrite for speed can be
/// shown not to have changed what the code means - a faster function that answers
/// differently is not a faster function.
///
/// Deliberately written the slow, obvious way. A division and a modulo per bit,
/// exactly as the code it replaced did, because a reference that shares a trick
/// with the thing it checks checks nothing.
enum SlowBitmap {

    static func bit(_ base: UnsafeRawPointer, _ index: Int) -> Bool {
        let byte = base.loadUnaligned(fromByteOffset: index / 8, as: UInt8.self)
        return byte & (1 << UInt8(index % 8)) != 0
    }

    static func set(
        _ base : UnsafeMutableRawPointer,
        from first: Int,
        count  : Int,
        used   : Bool
    ) {
        for index in first..<(first + count) {
            var byte = base.loadUnaligned(fromByteOffset: index / 8, as: UInt8.self)

            if used { byte |=  (1 << UInt8(index % 8)) }
            else    { byte &= ~(1 << UInt8(index % 8)) }

            base.storeBytes(of: byte, toByteOffset: index / 8, as: UInt8.self)
        }
    }

    static func allClear(
        _ base : UnsafeRawPointer,
        from first: Int,
        count  : Int
    ) -> Bool {
        for index in first..<(first + count) where bit(base, index) { return false }
        return true
    }

    static func clearCount(
        _ base : UnsafeRawPointer,
        from first: Int,
        count  : Int
    ) -> Int {
        var free = 0
        for index in first..<(first + count) where !bit(base, index) { free += 1 }
        return free
    }

    static func leadingClear(_ base: UnsafeRawPointer, bits: Int) -> Int {
        var run = 0
        while run < bits, !bit(base, run) { run += 1 }
        return run
    }

    static func trailingClear(_ base: UnsafeRawPointer, bits: Int) -> Int {
        var run = 0
        while run < bits, !bit(base, bits - 1 - run) { run += 1 }
        return run
    }

    /// First fit, a bit at a time, which is the answer the fold has to give.
    static func firstRun(
        _ base : UnsafeRawPointer,
        ofAtLeast count: Int,
        from first: Int,
        bits   : Int
    ) -> Int? {

        guard count > 0, first < bits else { return nil }

        var running = 0
        var start   = first

        for index in first..<bits {
            if bit(base, index) {
                running = 0
                start   = index + 1
                continue
            }

            running += 1
            if running == count { return start }
        }

        return nil
    }
}
