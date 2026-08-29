//
//  Ring.swift
//  ReixOS
//
//  Created by Eliomar on 29/06/2026.
//


@frozen
public struct Ring {

    @usableFromInline
    static let newline = UInt8(ascii: "\n")

    @usableFromInline
    static let dataOffset = 8

    @usableFromInline
    var base: UnsafeMutableRawPointer // SHM Buffer

    @usableFromInline
    let cap : Int

    @usableFromInline
    let mask: UInt32


    public init(
        base      : UnsafeMutableRawPointer,
        regionSize: Int
    ) {

        let usable = regionSize - Self.dataOffset
        var size   = 1

        // Set ring size
        while size * 2 <= usable { size *= 2 }

        self.base = base
        self.cap  = size
        self.mask = UInt32(size - 1)

    }


    /// The shared region this ring was built over.
    ///
    /// The side that obtained the region from `shmMap` needs the address back to
    /// release the mapping when it stops using the ring: `shmMap` hands out an
    /// address and nothing else, so nobody else can recover it.
    public var regionBase: UnsafeMutableRawPointer { base }

    @inlinable
    var head: UInt32 {
        get {
            base.load(fromByteOffset: 0, as: UInt32.self)
        }

        nonmutating set {
            base.storeBytes(of: newValue, toByteOffset: 0, as: UInt32.self)
        }
    }

    @inlinable
    var tail: UInt32 {
        get {
            base.load(fromByteOffset: 4, as: UInt32.self)
        }

        nonmutating set {
            base.storeBytes(of: newValue, toByteOffset: 4, as: UInt32.self)
        }
    }

    @inlinable
    public var isEmpty: Bool {
        (head & mask) == (tail & mask)
    }

    @inlinable
    public var count: Int {
        Int((tail &- head) & mask)
    }

    @inlinable
    public var isFull: Bool {
        count == cap - 1
    }


    @inlinable
    public func push(_ byte: UInt8) -> Bool {

        let currentTail = tail & mask
        let next        = (currentTail &+ 1) & mask

        guard next != (head & mask) else { return false }

        base.storeBytes(
            of          : byte,
            toByteOffset: Self.dataOffset + Int(currentTail),
            as          : UInt8.self
        )

        dmbISH()
        tail = next

        return true
    }

    /// Appends up to `count` bytes from `bytes` and returns how many were taken.
    ///
    /// A whole batch costs one barrier instead of one per byte: `head` and `tail`
    /// are read once into locals, the bytes are copied out in at most two
    /// contiguous spans (two only when the batch straddles the end of the
    /// buffer) and the new `tail` is published once, at the end.
    ///
    /// - Returns: the number of bytes accepted, `0` when the ring is full.
    @inlinable
    public func push(
        _ bytes: UnsafeRawPointer,
          count: Int
    ) -> Int {

        guard count > 0 else { return 0 }


        let currentTail = tail & mask
        let currentHead = head & mask


        let free = Int((currentHead &- currentTail &- 1) & mask)
        let take = min(count, free)

        guard take > 0 else { return 0 }

        let firstSpan = min(take, cap - Int(currentTail))

        (base + Self.dataOffset + Int(currentTail)).copyMemory(
            from     : bytes,
            byteCount: firstSpan
        )

        if take > firstSpan {
            (base + Self.dataOffset).copyMemory(
                from     : bytes + firstSpan,
                byteCount: take - firstSpan
            )
        }

        dmbISH()
        tail = (currentTail &+ UInt32(take)) & mask

        return take
    }

    /// Removes and returns the next byte from the ring buffer.
    ///
    /// This method dequeues a single byte from the head of the ring buffer.
    /// A memory barrier (`dmbISH`) ensures proper ordering when the buffer
    /// is shared between processes via shared memory.
    ///
    /// - Returns: The next byte in the buffer, or `nil` if the buffer is empty.
    @inlinable
    public func pop() -> UInt8? {

        let currentHead = head & mask
        guard currentHead != (tail & mask) else { return nil }

        // Acquire
        dmbISH()
        let byte = base.load(
            fromByteOffset: Self.dataOffset + Int(currentHead),
            as            : UInt8.self
        )

        // Release
        dmbISH()
        head = (currentHead &+ 1) & mask

        return byte
    }

    /// Hands the next complete line, everything up to and including the first
    /// `\n` to `sink` as one or two contiguous spans, then frees those slots.
    ///
    /// This is the batch counterpart of `nextLineLength()` plus a `pop()` loop:
    /// it walks the queued bytes once, pays a single acquire barrier for the
    /// whole line instead of one per byte, and hands the bytes out in place
    /// rather than re-loading each of them.
    ///
    /// `sink` is called with at most two spans because the line may straddle the
    /// end of the buffer. It must consume the bytes before returning: the slots
    /// go back to the producer as soon as this method returns.
    ///
    /// - Returns: `false` when the ring holds no complete line. A partial line
    ///            stays queued until the producer writes its newline.
    public func consumeLine(_ sink: (UnsafeRawPointer, Int) -> Void) -> Bool {

        let currentHead = head & mask
        let currentTail = tail & mask

        guard currentHead != currentTail else { return false }

        // Acquire
        dmbISH()

        let available = Int((currentTail &- currentHead) & mask)

        guard let length = lineLength(
            from     : Int(currentHead),
            available: available
        ) else { return false }

        emit(from: currentHead, length: length, to: sink)

        return true
    }

    /// Publishes the consumed head only after every span is accepted by `sink`.
    public func consumeLineChecked(
        _ sink: (
            UnsafeRawPointer,
            Int,
            UnsafeRawPointer?,
            Int)
        -> Bool
    ) -> Bool {

        let currentHead = head & mask
        let currentTail = tail & mask

        guard currentHead != currentTail else { return false }

        dmbISH()

        let available = Int((currentTail &- currentHead) & mask)
        guard let length = lineLength(
            from     : Int(currentHead),
            available: available
        ) else { return false }

        return emitChecked(from: currentHead, length: length, to: sink)
    }

    /// Hands every queued byte to `sink`, newline or not, and frees the slots.
    ///
    /// The escape hatch for a producer that filled the ring without ever writing
    /// a `\n`: complete lines are all `consumeLine` hands out, so without this
    /// the producer would wait forever for a slot that never frees up.
    ///
    /// - Returns: the number of bytes handed to `sink`.
    @discardableResult
    public func consumeAll(_ sink: (UnsafeRawPointer, Int) -> Void) -> Int {

        let currentHead = head & mask
        let currentTail = tail & mask

        guard currentHead != currentTail else { return 0 }

        // Acquire
        dmbISH()

        let available = Int((currentTail &- currentHead) & mask)
        emit(from: currentHead, length: available, to: sink)

        return available
    }

    /// Publishes the consumed head only after every queued span is accepted.
    public func consumeAllChecked(
        _ sink: (
            UnsafeRawPointer,
            Int,
            UnsafeRawPointer?,
            Int
        ) -> Bool
    ) -> Int {

        let currentHead = head & mask
        let currentTail = tail & mask

        guard currentHead != currentTail else { return 0 }

        dmbISH()

        let available = Int((currentTail &- currentHead) & mask)
        return emitChecked(from: currentHead, length: available, to: sink) ? available : 0
    }

    /// Length of the first line inside the `available` bytes that start at
    /// `start`, newline included, or `nil` when none of them is a `\n` yet.
    ///
    /// Caller must already have issued the acquire barrier: this reads the data.
    private func lineLength(
        from start    : Int,
             available: Int
    ) -> Int? {

        let data      = base + Self.dataOffset
        let firstSpan = min(available, cap - start)

        for offset in 0..<firstSpan {
            if data.load(fromByteOffset: start + offset, as: UInt8.self) == Self.newline {
                return offset + 1
            }
        }

        // The rest wrapped around to index 0.
        for offset in 0..<(available - firstSpan) {
            if data.load(fromByteOffset: offset, as: UInt8.self) == Self.newline {
                return firstSpan + offset + 1
            }
        }

        return nil
    }

    /// Hands `length` bytes starting at `start` to `sink` and frees their slots.
    ///
    /// Caller must already have issued the acquire barrier.
    @inline(__always)
    private func emit(
        from  start: UInt32,
        length     : Int,
        to    sink : (UnsafeRawPointer, Int) -> Void
    ) {

        let data      = base + Self.dataOffset
        let firstSpan = min(length, cap - Int(start))

        sink(UnsafeRawPointer(data + Int(start)), firstSpan)

        if length > firstSpan {
            sink(UnsafeRawPointer(data), length - firstSpan)
        }

        // Release
        dmbISH()
        head = (start &+ UInt32(length)) & mask
    }

    private func emitChecked(
        from start : UInt32,
             length: Int,
        to   sink  : (UnsafeRawPointer, Int, UnsafeRawPointer?, Int) -> Bool
    ) -> Bool {

        let data        = base + Self.dataOffset
        let firstSpan   = min(length, cap - Int(start))
        let secondCount = length - firstSpan
        let second      = secondCount > 0 ? UnsafeRawPointer(data) : nil

        guard sink(
            UnsafeRawPointer(data + Int(start)),
            firstSpan,
            second,
            secondCount
        ) else { return false }

        dmbISH()

        head = (start &+ UInt32(length)) & mask
        return true
    }

    public func nextLineLength() -> Int? {

        let end      = tail & mask
        var iterator = head & mask

        guard iterator != end else { return nil }

        // Acquire
        dmbISH()

        var length = 0
        while iterator != end {
            let byte = base.load(
                fromByteOffset: Self.dataOffset + Int(iterator),
                as            : UInt8.self
            )
            length += 1

            if byte == Self.newline { return length }

            iterator = (iterator + 1) & mask
        }

        return nil
    }

    @inline(__always)
    public func reset() {
        head = 0
        tail = 0

        // Release
        dmbISH()
    }
}
