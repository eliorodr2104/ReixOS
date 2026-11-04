//
//  LogRing.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/08/2026.
//

/// Fixed-capacity byte ring holding rendered log lines until something
/// flushes them to the UART.
///
/// Lives in `.bss` as a plain `static var`. The logger is the first thing
/// the kernel uses and the last thing it uses, so it must not depend on
/// the heap: at the point `[ BOOT  ][PPM ] ...` is printed there is no
/// allocator yet, and at the point the panic report is printed there may
/// no longer be one.
///
/// Records are framed and variable length, so a short line costs a short
/// record instead of a fixed slot:
///
///     +--------------+----------+-----------+---------------+
///     | timestamp: 8 | level: 1 | tagLen: 1 | payloadLen: 2 |  header
///     +--------------+----------+-----------+---------------+
///     | tag     bytes (tagLen)                              |
///     +-----------------------------------------------------+
///     | payload bytes (payloadLen)                          |
///     +-----------------------------------------------------+
///
/// Header fields are stored little-endian, one byte at a time: records are
/// packed back to back so a header is almost never naturally aligned, and
/// the kernel is built with strict-align codegen. Records straddle the
/// wrap point freely, since every access masks its own cursor, so there is
/// no padding record and no wasted tail.
///
/// - Invariant: **producer and consumer can never overlap.** EL1 is
///   non-preemptible with IRQs masked (`daifset #3`) on every path that
///   touches this ring, so a writer only ever runs between two whole
///   records and the drain only ever runs between two whole records. That
///   is the entire reason none of the cursors are atomic and no barrier is
///   issued anywhere in this file. If the kernel ever becomes preemptible,
///   or a second core comes up, this is the first thing that breaks.
enum LogRing {

    /// Ring capacity in bytes. Power of two so cursors are masked rather
    /// than divided. Must stay in step with the `InlineArray` size below.
    static let capacity = 8192

    /// `timestamp` + `level` + `tagLen` + `payloadLen`.
    static let headerSize = 12

    /// Severity byte for a record that carries no severity prefix at all:
    /// the bare `kprint(_:)` form used by the banner and the panic report.
    /// Chosen outside the `LogLevel` raw range so `LogLevel(rawValue:)`
    /// simply returns `nil` for it.
    static let rawLevel: UInt8 = 0xFF

    private static let mask = UInt64(capacity - 1)

    private static var storage = InlineArray<8192, UInt8>(repeating: 0)

    /// Cursors are monotonic and never wrapped in place: `head &- tail` is
    /// the number of live bytes, and masking happens only at the point of
    /// access. Sixty-four bits at UART speed will not run out.
    private static var head: UInt64 = 0
    private static var tail: UInt64 = 0

    /// Oldest byte the drain still owes the wire.
    ///
    /// Distinct from `tail` because the ring is two things at once: a queue
    /// of output not yet sent, bounded by this cursor, and a history the
    /// panic report quotes, bounded by `tail`. Draining consumes the queue
    /// and leaves the history alone, so a report in `.deferred` mode still
    /// finds the lines that led up to the fault instead of a ring the timer
    /// tick emptied. It is also what tells an eviction whether the record it
    /// is dropping ever reached anybody.
    ///
    /// - Invariant: `tail <= flushCursor <= head`.
    private static var flushCursor: UInt64 = 0

    /// Records overwritten before anybody drained them, since the drain
    /// last reported the count.
    private static var lostRecords: UInt64 = 0

    /// Records that outgrew the whole ring and lost their tail, since the
    /// drain last reported the count. Counted separately from `lostRecords`
    /// because a clipped line still reaches the reader and an evicted one
    /// never does.
    private static var truncatedRecords: UInt64 = 0

    /// Where the record currently being streamed in starts, and whether
    /// there is one. Eviction must never walk over it.
    private static var recordStart: UInt64 = 0
    private static var recording           = false

    /// Whether the open record has already been clipped, so the count moves
    /// once per record instead of once per dropped byte.
    private static var truncating = false


    // MARK: - State

    static var isEmpty    : Bool   { head == tail        }
    static var hasPending : Bool   { head != flushCursor }
    static var isRecording: Bool   { recording           }
    static var lost       : UInt64 { lostRecords         }
    static var truncated  : UInt64 { truncatedRecords    }

    static func clearLost()      { lostRecords      = 0 }
    static func clearTruncated() { truncatedRecords = 0 }


    // MARK: - Write path

    /// Opens a record: reserves the header, stamps it and copies the tag.
    ///
    /// Payload bytes are appended one at a time afterwards because the
    /// interpolation has no idea how long the line will be. `end()` patches
    /// the length back into the header once it does.
    ///
    /// Every entry point on the write path is `@inline(never)`: the sink
    /// tests one flag and calls in here. Letting these bodies inline into
    /// each of the sixty-odd `kprint` sites doubled the size of the boot
    /// path for a branch that is not even taken in the shipped
    /// configuration.
    @inline(never)
    static func begin(level: UInt8, tag: StaticString?, timestamp: UInt64) {
        // A caller that forgot to close its record would otherwise leave a
        // header with a bogus length behind.
        if recording { end() }

        var tagLength = 0
        tag?.withUTF8Buffer { tagLength = $0.count }

        guard makeRoom(for: headerSize &+ tagLength) else {
            lostRecords &+= 1
            return
        }

        recordStart = head
        recording   = true
        truncating  = false

        var stamp = timestamp
        for _ in 0..<8 {
            push(UInt8(truncatingIfNeeded: stamp))
            stamp >>= 8
        }

        push(level)
        push(UInt8(truncatingIfNeeded: tagLength))
        push(0) // payloadLen low, patched by `end()`
        push(0) // payloadLen high, patched by `end()`

        tag?.withUTF8Buffer { buffer in
            for byte in buffer { push(byte) }
        }
    }


    /// Appends one payload byte to the open record.
    ///
    /// Bytes arriving outside a record are the caller's problem: the sink
    /// checks `isRecording` before it routes anything here.
    ///
    /// A record that has started being clipped stays clipped to the end.
    /// Trimming gives a byte or two back, and without `truncating` in the
    /// guard the next byte would walk straight into the hole it just made.
    @inline(never)
    static func appendPayload(_ byte: UInt8) {
        guard recording, !truncating else { return }

        guard makeRoom(for: 1) else {
            truncate()
            return
        }

        push(byte)
    }


    /// Bulk overload so a whole literal segment costs the sink one call
    /// instead of one call per character.
    @inline(never)
    static func appendPayload(_ value: StaticString) {
        value.withUTF8Buffer { buffer in
            for byte in buffer { appendPayload(byte) }
        }
    }


    /// Closes the open record by patching its payload length in place.
    @inline(never)
    static func end() {
        guard recording else { return }

        let tagLength     = UInt64(load(at: recordStart &+ 9))
        let payloadLength = head &- recordStart &- UInt64(headerSize) &- tagLength

        // Bounded by the ring capacity, so it always fits in 16 bits.
        store(UInt8(truncatingIfNeeded: payloadLength     ), at: recordStart &+ 10)
        store(UInt8(truncatingIfNeeded: payloadLength >> 8), at: recordStart &+ 11)

        recording  = false
        truncating = false
    }


    /// Declares every byte in the ring already on the wire.
    ///
    /// The sink calls this after any record it wrote through as it built it.
    /// Without it the queue and the history would be the same cursor, and the
    /// first `.deferred` drain would resend the whole `.synchronous` boot log,
    /// interleaved with whatever user space was printing at the time.
    @inline(__always)
    static func markFlushed() {
        flushCursor = head
    }


    /// Marks the open record clipped and pulls `head` back off a character
    /// the clip landed inside.
    ///
    /// Reached only for a line longer than the whole ring, where `makeRoom`
    /// refuses to evict the record being written. Every byte from here on is
    /// dropped, so the cut point is wherever the first one arrived, which is
    /// as likely to be the middle of a multi-byte sequence as anywhere else.
    ///
    /// Runs once per record, not once per dropped byte: `appendPayload` stops
    /// coming here as soon as `truncating` is set.
    private static func truncate() {
        truncating        = true
        truncatedRecords &+= 1

        trimPartialCharacter()
    }


    /// Removes a trailing UTF-8 sequence that never got all its bytes.
    ///
    /// Walks back over the continuation bytes to the byte that announced the
    /// sequence, and drops the lot only when fewer arrived than it announced,
    /// so a line that happens to end on a complete character keeps it.
    private static func trimPartialCharacter() {
        let payloadStart = recordStart
                         &+ UInt64(headerSize)
                         &+ UInt64(load(at: recordStart &+ 9))

        var cursor = head
        var trail  = 0

        while trail < 3, cursor > payloadStart {
            let byte = load(at: cursor &- 1)

            guard byte & 0xC0 != 0x80 else {
                cursor &-= 1
                trail  &+= 1
                continue
            }

            if characterLength(byte) > trail &+ 1 { head = cursor &- 1 }

            return
        }
    }


    /// How many bytes the sequence starting with `lead` is meant to have.
    /// Anything that is not a valid lead byte counts as one, which leaves it
    /// where it is instead of eating the bytes around it.
    @inline(__always)
    private static func characterLength(_ lead: UInt8) -> Int {
        switch lead {
            case 0xF0...0xF7: 4
            case 0xE0...0xEF: 3
            case 0xC0...0xDF: 2
            default         : 1
        }
    }


    // MARK: - Read path

    /// A record located in the ring. Only the header is decoded; the tag
    /// and payload stay in place and are read byte by byte, so nothing is
    /// ever copied out.
    struct Record {
        var timestamp    : UInt64 = 0
        var level        : UInt8  = 0
        var tagLength    : Int    = 0
        var payloadLength: Int    = 0

        /// Cursor of the record header, unmasked.
        var cursor       : UInt64 = 0
    }


    /// The oldest complete record, or `nil` when there is nothing to flush.
    ///
    /// The second guard is defensive. The invariant at the top of this file
    /// says a drain can never begin while a record is half written; if one
    /// ever does, stopping at the open record beats decoding a bogus length.
    static func peek() -> Record? {
        guard head != tail else { return nil }

        guard !recording || tail != recordStart else { return nil }

        return decode(at: tail)
    }


    /// The oldest record the drain has not sent yet, or `nil` when the wire
    /// is up to date. The queue-side counterpart of `peek`.
    static func pending() -> Record? {
        guard head != flushCursor else { return nil }

        guard !recording || flushCursor != recordStart else { return nil }

        return decode(at: flushCursor)
    }


    /// Visits every complete record, oldest first, and leaves the ring
    /// exactly as it was found.
    ///
    /// `peek` and `retire` are a drain's API: both work off the read cursor,
    /// so a reader that only wants to look has to move that cursor and then
    /// put it back. This walks a cursor of its own instead, which is what the
    /// panic report needs and what a future host-side dumper will need too.
    ///
    /// The second loop condition is defensive: a corrupt length would
    /// otherwise step past `head` and wrap, and the walk would never end.
    ///
    /// - Invariant: as everywhere else in this file, the caller must have
    ///   IRQs masked so no writer can evict underneath the walk.
    @discardableResult
    static func forEachRecord(_ body: (Record) -> Void) -> Int {
        var cursor  = tail
        var visited = 0

        while cursor != head, head &- cursor <= UInt64(capacity) {
            guard !recording || cursor != recordStart else { break }

            let record = decode(at: cursor)

            body(record)

            cursor = cursor
                   &+ UInt64(headerSize &+ record.tagLength &+ record.payloadLength)

            visited &+= 1
        }

        return visited
    }


    /// Decodes the header sitting at `cursor`. The tag and payload stay in
    /// the ring and are read through `tagByte` / `payloadByte`.
    private static func decode(at cursor: UInt64) -> Record {
        var timestamp: UInt64 = 0
        for i in 0..<8 {
            timestamp |= UInt64(load(at: cursor &+ UInt64(i))) << UInt64(i &* 8)
        }

        return Record(
            timestamp    : timestamp,
            level        : load(at: cursor &+ 8),
            tagLength    : Int(load(at: cursor &+ 9)),
            payloadLength: payloadLength(at: cursor),
            cursor       : cursor
        )
    }


    @inline(__always)
    static func tagByte(_ record: Record, _ index: Int) -> UInt8 {
        load(at: record.cursor &+ UInt64(headerSize &+ index))
    }


    @inline(__always)
    static func payloadByte(_ record: Record, _ index: Int) -> UInt8 {
        load(at: record.cursor &+ UInt64(headerSize &+ record.tagLength &+ index))
    }


    /// Retires a record the drain has finished rendering.
    ///
    /// The read cursor only ever moves by a whole record, and only after
    /// the record's last byte has reached the UART. A half-consumed record
    /// therefore does not exist as far as the write path is concerned:
    /// whenever a writer evicts, `tail` is sitting on a valid header.
    static func retire(_ record: Record) {
        tail = record.cursor
             &+ UInt64(headerSize &+ record.tagLength &+ record.payloadLength)
    }


    /// Acknowledges a record whose last byte has reached the UART.
    ///
    /// Moves only the queue cursor: the record stays in the ring as history
    /// until an eviction needs the space.
    static func flushed(_ record: Record) {
        flushCursor = record.cursor
                    &+ UInt64(headerSize &+ record.tagLength &+ record.payloadLength)
    }


    // MARK: - Ring mechanics

    /// Frees at least `bytes`, dropping whole records from the tail.
    ///
    /// Overwrite-oldest: a writer never blocks and never waits for a
    /// reader. Eviction advances the read cursor a whole record at a time,
    /// which is what keeps `tail` a valid header boundary at every instant.
    ///
    /// Returns `false` only when the request cannot be satisfied without
    /// eating the record currently being written, i.e. a single line longer
    /// than the whole ring. The caller then drops the byte, which truncates
    /// that one line instead of corrupting the ring.
    ///
    /// A record is counted lost only when the drain had not sent it. The rest
    /// were on the wire long before the space they occupied was needed, and
    /// calling those lost is how a healthy ring ends up reporting thousands.
    private static func makeRoom(for bytes: Int) -> Bool {
        guard bytes <= capacity else { return false }

        while capacity &- Int(head &- tail) < bytes {
            guard !recording || tail != recordStart else { return false }

            let next = tail
                     &+ UInt64(headerSize &+ Int(load(at: tail &+ 9)) &+ payloadLength(at: tail))

            if tail == flushCursor {
                flushCursor  = next
                lostRecords &+= 1
            }

            tail = next
        }

        return true
    }


    @inline(__always)
    private static func payloadLength(at cursor: UInt64) -> Int {
        Int(load(at: cursor &+ 10)) | (Int(load(at: cursor &+ 11)) << 8)
    }


    @inline(__always)
    private static func push(_ byte: UInt8) {
        store(byte, at: head)
        head &+= 1
    }


    @inline(__always)
    private static func store(_ byte: UInt8, at cursor: UInt64) {
        storage[Int(cursor & mask)] = byte
    }


    @inline(__always)
    private static func load(at cursor: UInt64) -> UInt8 {
        storage[Int(cursor & mask)]
    }
}
