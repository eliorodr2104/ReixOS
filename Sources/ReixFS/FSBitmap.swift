//
//  FSBitmap.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

/// One block of the block map, taken a word at a time.
///
/// Every operation here is over a range of bits inside *one* block, because a
/// block is the unit the disk moves and the unit the caller has in hand. What
/// composes ranges across blocks is `FileSystemSpace`; what is here is the
/// arithmetic, and it is here because arithmetic can be shown to be right without
/// a disk: the tests keep a bit-at-a-time implementation of every one of these
/// and compare the two answer for answer.
///
/// The bit at a time is what this replaces. Claiming a run of thirty-two blocks
/// was thirty-two divisions, shifts and byte stores; asking whether a run was
/// free was thirty-two more; and the scan for a free run tested every block on
/// the disk unless a whole word happened to be all-ones or all-zeros, which on a
/// disk with every other block used is never. Measured at fifty milliseconds for
/// one refused allocation on a sixty-five thousand block disk, which is a request
/// a client makes.
enum FSBitmap {

    /// Bits one word of the map accounts for.
    static var bitsPerWord: Int { 64 }

    /// Bytes one word takes.
    static var bytesPerWord: Int { 8 }


    /// The word holding bit `index * 64` of the block at `base`.
    ///
    /// Little-endian, and that is not a formality. Bit *n* of the map lives in
    /// byte *n / 8* at bit *n % 8*, so for `trailingZeroBitCount` to name the
    /// lowest-numbered *block* the word's low byte has to be the map's first
    /// byte. A native load says so on this machine and the opposite on the other
    /// kind, and every answer below would then name the wrong block.
    @inline(__always)
    static func word(_ base: UnsafeRawPointer, _ index: Int) -> UInt64 {
        UInt64(littleEndian: base.loadUnaligned(
            fromByteOffset: index * bytesPerWord, as: UInt64.self
        ))
    }

    @inline(__always)
    static func store(
        _ base : UnsafeMutableRawPointer,
        _ index: Int,
        _ value: UInt64
    ) {
        base.storeBytes(
            of          : value.littleEndian,
            toByteOffset: index * bytesPerWord,
            as          : UInt64.self
        )
    }


    /// The bits `first ..< first + count` of one word, as ones.
    ///
    /// Clipped to the end of the word, so a caller may hand over a count that
    /// runs past it. Written with a shift *right* first because the obvious way
    /// does not work at the width of the word: `1 << 64` is not a thing and
    /// `(1 << 64) - 1` is not sixty-four ones.
    @inline(__always)
    static func mask(from first: Int, count: Int) -> UInt64 {

        guard first >= 0, first < bitsPerWord, count > 0 else { return 0 }

        let width = min(count, bitsPerWord - first)
        let low   = UInt64.max >> UInt64(bitsPerWord - width)

        return low << UInt64(first)
    }


    /// Sets or clears the bits `first ..< first + count`.
    ///
    /// One read-modify-write per word rather than per bit, so a run inside one
    /// word is one of each however long it is.
    ///
    /// Two cases are written out rather than left to the loop, and neither is
    /// premature: appending to a file claims one block at a time, which is the
    /// commonest write this file system makes, and a run inside one word is the
    /// next commonest. Through the loop the single bit cost four calls and a
    /// branch where a bit at a time cost a load and a store, and that was a real
    /// regression on the small case - so one bit is a byte, deliberately.
    static func set(
        _ base : UnsafeMutableRawPointer,
        from first: Int,
        count  : Int,
        used   : Bool
    ) {
        guard first >= 0, count > 0 else { return }

        // One bit is a byte. See the doc above.
        if count == 1 {
            let at = first / 8

            var byte = base.loadUnaligned(fromByteOffset: at, as: UInt8.self)

            if used { byte |=  (1 << UInt8(first % 8)) }
            else    { byte &= ~(1 << UInt8(first % 8)) }

            base.storeBytes(of: byte, toByteOffset: at, as: UInt8.self)
            return
        }

        let inside = first % bitsPerWord

        if inside + count <= bitsPerWord {
            let at   = (first / bitsPerWord) * bytesPerWord
            let bits = (UInt64.max >> UInt64(bitsPerWord - count)) << UInt64(inside)

            let was = UInt64(littleEndian: base.loadUnaligned(
                fromByteOffset: at, as: UInt64.self
            ))

            base.storeBytes(
                of          : (used ? was | bits : was & ~bits).littleEndian,
                toByteOffset: at,
                as          : UInt64.self
            )

            return
        }

        var bit = first
        let end = first + count

        while bit < end {
            let index  = bit / bitsPerWord
            let inside = bit % bitsPerWord
            let width  = min(end - bit, bitsPerWord - inside)

            let bits = mask(from: inside, count: width)
            let was  = word(base, index)

            store(base, index, used ? was | bits : was & ~bits)

            bit += width
        }
    }


    /// Whether every one of the bits `first ..< first + count` is clear.
    ///
    /// The single-word case written out, for the reason `set` gives: a growing
    /// file asks about the blocks straight after the ones it has, and that is one
    /// word almost every time.
    static func allClear(
        _ base : UnsafeRawPointer,
        from first: Int,
        count  : Int
    ) -> Bool {

        guard first >= 0, count > 0 else { return false }

        // One bit is a byte, for the reason `set` gives.
        if count == 1 {
            let byte = base.loadUnaligned(fromByteOffset: first / 8, as: UInt8.self)
            return byte & (1 << UInt8(first % 8)) == 0
        }

        let inside = first % bitsPerWord

        if inside + count <= bitsPerWord {
            let at   = (first / bitsPerWord) * bytesPerWord
            let bits = (UInt64.max >> UInt64(bitsPerWord - count)) << UInt64(inside)

            let was = UInt64(littleEndian: base.loadUnaligned(
                fromByteOffset: at, as: UInt64.self
            ))

            return was & bits == 0
        }

        var bit = first
        let end = first + count

        while bit < end {
            let index  = bit / bitsPerWord
            let inside = bit % bitsPerWord
            let width  = min(end - bit, bitsPerWord - inside)

            guard word(base, index) & mask(from: inside, count: width) == 0 else {
                return false
            }

            bit += width
        }

        return true
    }


    /// How many of the bits `first ..< first + count` are clear.
    static func clearCount(
        _ base : UnsafeRawPointer,
        from first: Int,
        count  : Int
    ) -> Int {

        guard first >= 0, count > 0 else { return 0 }

        var bit  = first
        let end  = first + count
        var free = 0

        while bit < end {
            let index  = bit / bitsPerWord
            let inside = bit % bitsPerWord
            let width  = min(end - bit, bitsPerWord - inside)

            let bits = mask(from: inside, count: width)
            free += width - (word(base, index) & bits).nonzeroBitCount

            bit += width
        }

        return free
    }


    /// Clear bits at the very start of the block, up to `bits`.
    ///
    /// Half of what stitches a run across two bitmap blocks: this block's leading
    /// run and the previous one's trailing run are one run.
    static func leadingClear(_ base: UnsafeRawPointer, bits: Int) -> Int {

        guard bits > 0 else { return 0 }

        var run = 0

        while run < bits {
            let index = run / bitsPerWord
            let width = min(bits - run, bitsPerWord)

            let free = ~word(base, index) & mask(from: 0, count: width)

            // A word with something taken in it ends the run, and says where.
            guard free == mask(from: 0, count: width) else {
                return run + (~free).trailingZeroBitCount
            }

            run += width
        }

        return bits
    }


    /// Clear bits at the very end of the block, counting back from `bits`.
    static func trailingClear(_ base: UnsafeRawPointer, bits: Int) -> Int {

        guard bits > 0 else { return 0 }

        var run = 0

        while run < bits {
            let high  = bits - run                       // one past the last bit to look at
            let index = (high - 1) / bitsPerWord
            let at    = index * bitsPerWord
            let width = high - at

            let free = ~word(base, index) & mask(from: 0, count: width)

            guard free == mask(from: 0, count: width) else {
                // Pushed up so the last bit of the window is the top of the word,
                // and then the ones above it are the run.
                let up = free << UInt64(bitsPerWord - width)
                return run + (~up).leadingZeroBitCount
            }

            run += width
        }

        return bits
    }


    /// Where a run of `count` clear bits starts inside one word, or nothing.
    ///
    /// The fold is the whole trick. A run of `count` starting at *i* means bits
    /// *i* through *i + count - 1* are all clear, so
    /// `free & (free >> 1) & (free >> 2) ...` has a bit at *i* exactly where such
    /// a run begins. Folding by doubling costs about log(count) ANDs for the whole
    /// word, and a word with nothing wide enough in it is rejected by one
    /// comparison against zero - which is what a disk with every other block used
    /// costs, and what used to cost sixty-four tests with a division in each.
    ///
    /// `high` is one past the last usable bit, so a run that would carry past the
    /// end of the block is not offered.
    @inline(__always)
    static func runStart(inside free: UInt64, count: Int, upTo high: Int) -> Int? {

        guard count > 0, count <= high, count <= bitsPerWord else { return nil }

        var folded = free
        var have   = 1

        while have < count {
            let step = min(have, count - have)
            folded &= folded >> UInt64(step)
            have   += step
        }

        // Starts that would run off the end of the window are not starts.
        folded &= mask(from: 0, count: high - count + 1)

        guard folded != 0 else { return nil }

        return folded.trailingZeroBitCount
    }


    /// Where the first run of at least `count` clear bits at or after `first`
    /// begins, within the first `bits` of this block, or nothing.
    ///
    /// Word at a time, and a word that cannot hold a run that wide is rejected
    /// whole: see `runStart(inside:count:upTo:)`. What the `carry` is for is the
    /// run that straddles two words, which the fold inside one word cannot see.
    static func firstRun(
        _ base : UnsafeRawPointer,
        ofAtLeast count: Int,
        from first: Int,
        bits   : Int
    ) -> Int? {

        guard count > 0, first >= 0, first < bits else { return nil }

        var carry      = 0      // clear bits running into this word from the last
        var carryStart = 0

        var index = first / bitsPerWord

        while index * bitsPerWord < bits {
            let at   = index * bitsPerWord
            let low  = max(first - at, 0)
            let high = min(bits - at, bitsPerWord)

            guard low < high else { break }

            // A whole word needs no window, which is every word but the first
            // and the last.
            let taken = word(base, index)
            let free  = (low == 0 && high == bitsPerWord)
                ? ~taken
                : ~taken & mask(from: low, count: high - low)

            // The run carried in continues only if this word is usable from its
            // very first bit and that bit is free.
            if carry > 0, low == 0, free & 1 != 0 {
                let lead = (~free).trailingZeroBitCount

                if carry + lead >= count { return carryStart }

                // The whole window free: the run goes on into the next word.
                if lead >= high {
                    carry += high
                    index += 1
                    continue
                }
            }

            if let inside = runStart(inside: free, count: count, upTo: high) {
                return at + inside
            }

            // Nothing wide enough in this word. What can still help is the run at
            // its top, joined to whatever the next word begins with.
            let trail = trailingClearOf(free, high: high)

            carry      = trail
            carryStart = at + high - trail

            index += 1
        }

        return nil
    }


    /// Clear bits at the top of one already-masked word.
    @inline(__always)
    private static func trailingClearOf(_ free: UInt64, high: Int) -> Int {

        guard high > 0 else { return 0 }

        if high == bitsPerWord { return (~free).leadingZeroBitCount }

        let up  = free << UInt64(bitsPerWord - high)
        let run = (~up).leadingZeroBitCount

        return min(run, high)
    }
}
