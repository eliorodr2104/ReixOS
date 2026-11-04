//
//  MemTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
@testable import ReixABI

/// The kernel's C entry points over `RawBytes`: what they do with a nil pointer,
/// which way `memmove` walks, and what a size_t too large for `Int` does.
///
/// `.serialized`, and the run needs `--no-parallel`: `RawBytes.misalignedAccesses`
/// is a global.
@Suite("Kernel memory entry points", .serialized)
struct MemTests {

    private static func bytes(_ count: Int, seed: Int) -> UnsafeMutableRawPointer {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        var index = 0
        while index < count {
            pointer.storeBytes(of: UInt8(truncatingIfNeeded: index &* 5 &+ seed), toByteOffset: index, as: UInt8.self)
            index += 1
        }
        return pointer
    }

    private static func read(_ pointer: UnsafeRawPointer, _ count: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: count)
        var index = 0
        while index < count { result[index] = pointer.load(fromByteOffset: index, as: UInt8.self); index += 1 }
        return result
    }


    @Test("every entry point returns its destination and refuses a nil pointer")
    func entryPointsReturnDestinationAndRefuseNil() {
        let destination = Self.bytes(8, seed: 1)
        let source      = Self.bytes(8, seed: 9)
        defer { destination.deallocate(); source.deallocate() }
        let before = Self.read(destination, 8)

        #expect(kernelMemset(nil, 0x5A, 4) == nil)

        #expect(kernelMemcpy(destination, nil, 4) == destination)
        #expect(kernelMemcpy(nil, source, 4) == nil)
        #expect(kernelMemmove(destination, nil, 4) == destination)
        #expect(kernelMemmove(nil, source, 4) == nil)
        #expect(Self.read(destination, 8) == before)

        #expect(kernelMemset(destination, 0x5A, 4) == destination)
        #expect(kernelMemcpy(destination, source, 4) == destination)
        #expect(kernelMemmove(destination, source, 4) == destination)
    }

    @Test("memmove walks whichever way the overlap needs")
    func memmoveChoosesTheDirectionTheOverlapNeeds() {
        RawBytes.misalignedAccesses = 0
        var failure: String?

        for count in Array(1...80) + [4096] {
            for shift in 0...40 where failure == nil {
                for forward in [true, false] {
                    let slab = Self.bytes(count + shift, seed: count)
                    defer { slab.deallocate() }
                    let original = Self.read(slab, count + shift)

                    let (destination, source) = forward ? (0, shift) : (shift, 0)
                    var expected = original
                    var index = 0
                    while index < count { expected[destination + index] = original[source + index]; index += 1 }

                    let result = kernelMemmove(slab + destination, slab + source, UInt(count))
                    if result != slab + destination || Self.read(slab, count + shift) != expected {
                        failure = "count \(count) shift \(shift) \(forward ? "down" : "up")"
                    }
                }
            }
        }

        #expect(failure == nil, "\(failure ?? "")")
        #expect(RawBytes.misalignedAccesses == 0)
    }

    @Test("a size above Int.max writes nothing")
    func aCountAboveIntMaxWritesNothing() {
        let slab   = Self.bytes(192, seed: 3)
        let source = Self.bytes(64, seed: 11)
        defer { slab.deallocate(); source.deallocate() }
        let before = Self.read(slab, 192)

        _ = kernelMemset(slab + 64, 0x5A, UInt.max)
        _ = kernelMemcpy(slab + 64, source, UInt.max)
        _ = kernelMemmove(slab + 64, source, UInt.max)

        #expect(Self.read(slab, 192) == before)
    }
}
