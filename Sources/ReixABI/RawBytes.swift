//
//  RawBytes.swift
//  ReixOS
//

/// The bulk byte moves under `memcpy`, `memset` and `memmove`, for the kernel and
/// for every program, written once in portable Swift SIMD.
///
/// Three rules shape the code, and a first draft broke each of them:
///
/// - Every access is naturally aligned, vector ones included. Boot calls these
///   before the MMU is on, where RAM is Device memory and an unaligned access is
///   an alignment fault; `-mstrict-align` only stops the compiler inventing one.
///   The head is aligned with 1, 2, 4 and 8-byte steps, the body moves 16-byte
///   lanes when both ends agree modulo 16 and 8-byte halves when they agree
///   modulo 8, and any other pair goes two bytes at a time.
/// - No loop stores one scalar, or one repeated value, per iteration. Loop idiom
///   recognition turns such a loop back into a call to `memset` or `memcpy`, and
///   from in here that call is infinite recursion. The short and ragged ends are
///   straight-line code; the `vector-primitives` post-check fails a build whose
///   image calls back.
/// - No `@_optimize(speed)`. Under the image's `-Osize` the loops already lower
///   to `ldp`/`stp` of q and d registers; `speed` turned the byte loops into calls
///   and bounced 8-byte words through the stack.
///
/// Vector registers are legal in the kernel because every exception saves the
/// whole FP/SIMD state before Swift runs. A count of zero or below writes nothing.
public enum RawBytes {

    typealias Lane = SIMD16<UInt8>
    typealias Half = SIMD8<UInt8>

    /// Sets `count` bytes at `base` to `byte`.
    public static func fill(
        _    base : UnsafeMutableRawPointer,
        with byte : UInt8,
        count     : Int
    ) {
        guard count > 0 else { return }

        var p = base
        var n = count

        guard n >= 16 else {
            if n & 8 != 0 {
                put(byte, at: p);     put(byte, at: p + 1); put(byte, at: p + 2); put(byte, at: p + 3)
                put(byte, at: p + 4); put(byte, at: p + 5); put(byte, at: p + 6); put(byte, at: p + 7)
                p += 8
            }
            if n & 4 != 0 {
                put(byte, at: p); put(byte, at: p + 1); put(byte, at: p + 2); put(byte, at: p + 3)
                p += 4
            }
            if n & 2 != 0 { put(byte, at: p); put(byte, at: p + 1); p += 2 }
            if n & 1 != 0 { put(byte, at: p) }
            return
        }

        let word = UInt64(byte) &* 0x0101_0101_0101_0101

        if UInt(bitPattern: p) & 1 != 0 { put(byte, at: p); p += 1; n &-= 1 }
        if UInt(bitPattern: p) & 2 != 0 { put(UInt16(truncatingIfNeeded: word), at: p); p += 2; n &-= 2 }
        if UInt(bitPattern: p) & 4 != 0 { put(UInt32(truncatingIfNeeded: word), at: p); p += 4; n &-= 4 }
        if UInt(bitPattern: p) & 8 != 0 { put(word, at: p); p += 8; n &-= 8 }

        let lanes = Lane(repeating: byte)
        while n >= 32 {
            put(lanes, at: p); put(lanes, at: p + 16)
            p += 32; n &-= 32
        }

        if n & 16 != 0 { put(lanes, at: p); p += 16 }
        if n & 8 != 0 { put(word, at: p); p += 8 }
        if n & 4 != 0 { put(UInt32(truncatingIfNeeded: word), at: p); p += 4 }
        if n & 2 != 0 { put(UInt16(truncatingIfNeeded: word), at: p); p += 2 }
        if n & 1 != 0 { put(byte, at: p) }
    }

    /// Copies `count` bytes from `source` to `destination`, lowest address first.
    ///
    /// Every block is read before it is written, so this is also `memmove` when
    /// the destination starts before the source.
    public static func copy(
        to   destination: UnsafeMutableRawPointer,
        from source     : UnsafeRawPointer,
        count           : Int
    ) {
        guard count > 0 else { return }

        var d = destination
        var s = source
        var n = count
        let skew = (UInt(bitPattern: d) ^ UInt(bitPattern: s)) & 15

        if n >= 16, skew & 7 == 0 {
            if UInt(bitPattern: d) & 1 != 0 { put(get(UInt8.self,  at: s), at: d); d += 1; s += 1; n &-= 1 }
            if UInt(bitPattern: d) & 2 != 0 { put(get(UInt16.self, at: s), at: d); d += 2; s += 2; n &-= 2 }
            if UInt(bitPattern: d) & 4 != 0 { put(get(UInt32.self, at: s), at: d); d += 4; s += 4; n &-= 4 }

            if skew == 0 {
                if UInt(bitPattern: d) & 8 != 0 { put(get(UInt64.self, at: s), at: d); d += 8; s += 8; n &-= 8 }

                while n >= 32 {
                    let low = get(Lane.self, at: s), high = get(Lane.self, at: s + 16)
                    put(low, at: d); put(high, at: d + 16)
                    d += 32; s += 32; n &-= 32
                }
            }

            while n >= 16 {
                let low = get(Half.self, at: s), high = get(Half.self, at: s + 8)
                put(low, at: d); put(high, at: d + 8)
                d += 16; s += 16; n &-= 16
            }

            if n & 8 != 0 { put(get(UInt64.self, at: s), at: d); d += 8; s += 8 }
            if n & 4 != 0 { put(get(UInt32.self, at: s), at: d); d += 4; s += 4 }
            if n & 2 != 0 { put(get(UInt16.self, at: s), at: d); d += 2; s += 2 }
            if n & 1 != 0 { put(get(UInt8.self,  at: s), at: d) }
            return
        }

        while n >= 2 {
            let first = get(UInt8.self, at: s), second = get(UInt8.self, at: s + 1)
            put(first, at: d); put(second, at: d + 1)
            d += 2; s += 2; n &-= 2
        }
        if n != 0 { put(get(UInt8.self, at: s), at: d) }
    }

    /// Copies `count` bytes highest address first, for a destination that starts
    /// inside the source. Two bytes a step: no measured caller moves much this way.
    public static func copyBackward(
        to   destination: UnsafeMutableRawPointer,
        from source     : UnsafeRawPointer,
        count           : Int
    ) {
        guard count > 0 else { return }

        var n = count
        while n >= 2 {
            let low = get(UInt8.self, at: source + (n &- 2)), high = get(UInt8.self, at: source + (n &- 1))
            put(high, at: destination + (n &- 1)); put(low, at: destination + (n &- 2))
            n &-= 2
        }
        if n != 0 { put(get(UInt8.self, at: source), at: destination) }
    }


    // MARK: - Aligned access

    #if !hasFeature(Embedded)
    /// Host-only count of accesses the alignment rule above would have broken.
    /// Each is done unaligned instead, so a suite reads a number, not a trap.
    nonisolated(unsafe) static var misalignedAccesses = 0
    #endif

    /// A typed store, which `-mstrict-align` emits as one instruction; `storeBytes`
    /// assumes nothing about alignment and would be split into bytes.
    @inline(__always)
    private static func put<T: BitwiseCopyable>(_ value: T, at address: UnsafeMutableRawPointer) {
        #if !hasFeature(Embedded)
        guard UInt(bitPattern: address) % UInt(MemoryLayout<T>.alignment) == 0 else {
            misalignedAccesses &+= 1
            address.storeBytes(of: value, as: T.self)
            return
        }
        #endif
        address.bindMemory(to: T.self, capacity: 1).pointee = value
    }

    @inline(__always)
    private static func get<T: BitwiseCopyable>(_ type: T.Type, at address: UnsafeRawPointer) -> T {
        #if !hasFeature(Embedded)
        guard UInt(bitPattern: address) % UInt(MemoryLayout<T>.alignment) == 0 else {
            misalignedAccesses &+= 1
            return address.loadUnaligned(as: T.self)
        }
        #endif
        return address.load(as: T.self)
    }
}
