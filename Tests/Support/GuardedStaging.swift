//
//  GuardedStaging.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.


import Darwin
@testable import Kernel

/// Where the blob sits inside its readable window.
///
/// The window is a whole number of host pages and a blob rarely is, so one end
/// is flush against its guard page and the other has slack. Which end matters:
/// `mprotect` cannot split a page, so the slack is genuinely readable and an
/// overrun into it does not fault.
public enum GuardedPlacement {

    /// The blob starts at the first readable byte. Use it when the window is
    /// sized from what the blob *declares* rather than from its length, so the
    /// declared extent, and not the buffer, is what the guard page bounds.
    case leading

    /// The blob ends on the last readable byte, so the trailing guard page sits
    /// exactly at its end and a single byte read past it faults. Use it when
    /// forward overrun is the failure being hunted.
    case trailing
}


/// The host page size, which decides the guard granularity.
///
/// 16 KiB on Apple silicon, not 4 KiB, which is why the slack described above
/// is worth naming rather than assuming away.
public let hostPageSize = Int(sysconf(_SC_PAGESIZE))


/// Byte written into the slack between the blob and its guard page.
///
/// Not zero on purpose. Zero is a valid FDT tag terminator and a valid ustar
/// end-of-archive marker, so an overrun into zeroed slack looks to both parsers
/// exactly like a well-formed end of input; `0xAA` looks like neither, and a
/// walk that wandered in there rejects rather than quietly succeeding.
public let guardPoison: UInt8 = 0xAA


/// Runs `body` over `bytes` staged inside a guarded, read-only window.
///
/// `declaring` is the readable extent to reserve, which for a blob that carries
/// its own length is what the blob says rather than what the array holds. The
/// window is rounded up to a page; anything between the blob and the end of the
/// window is poisoned, up to one page of it.
///
/// Returns `nil` when the mapping could not be made, which callers are expected
/// to treat as a failure rather than as a skip.
public func withGuardedBlob<R>(
    _ bytes  : [UInt8],
    declaring: Int? = nil,
    placement: GuardedPlacement = .leading,
    _ body   : (UnsafeRawPointer, Int) -> R
) -> R? {

    let declared = max(declaring ?? bytes.count, bytes.count)
    let window   = max(roundUpToPage(declared), hostPageSize)
    let total    = window + 2 * hostPageSize

    let mapping = mmap(nil, total, PROT_NONE, MAP_ANON | MAP_PRIVATE, -1, 0)
    guard let mapping, mapping != MAP_FAILED else { return nil }
    defer { munmap(mapping, total) }

    let readable = mapping.advanced(by: hostPageSize)
    guard mprotect(readable, window, PROT_READ | PROT_WRITE) == 0 else { return nil }

    let offset = placement == .leading ? 0 : window - bytes.count
    let base   = readable.advanced(by: offset)

    // Poison first, so the copy below always wins over it on the bytes it owns.
    poison(readable, window, blobStart: offset, blobCount: bytes.count)
    if !bytes.isEmpty {
        bytes.withUnsafeBytes { base.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }

    // Read-only for the parser: a write anywhere in the blob now faults too,
    // which is an invariant both parsers are supposed to hold.
    guard mprotect(readable, window, PROT_READ) == 0 else { return nil }

    return body(UnsafeRawPointer(base), bytes.count)
}


/// Fills up to one page of slack on each side of the blob.
///
/// Bounded to a page because the slack can be gigabytes when a mutated length
/// field declares one, and a parser that overruns does it by a few words.
private func poison(
    _ readable: UnsafeMutableRawPointer,
    _ window  : Int,
    blobStart : Int,
    blobCount : Int
) {
    let leading = min(blobStart, hostPageSize)
    if leading > 0 {
        readable.advanced(by: blobStart - leading)
            .initializeMemory(as: UInt8.self, repeating: guardPoison, count: leading)
    }

    let tailStart = blobStart + blobCount
    let trailing  = min(window - tailStart, hostPageSize)
    if trailing > 0 {
        readable.advanced(by: tailStart)
            .initializeMemory(as: UInt8.self, repeating: guardPoison, count: trailing)
    }
}


private func roundUpToPage(_ value: Int) -> Int {
    let pages = (value + hostPageSize - 1) / hostPageSize
    return pages * hostPageSize
}


// MARK: - Device tree staging

/// The header fields the FDT walk reads before it reads anything else, and the
/// arithmetic that says how far into the blob those fields let it go.
public enum DeviceTreeBlob {

    public static let headerSize = 40

    /// Offsets of the big-endian words that bound every later load. In header
    /// order: total size, struct offset, strings offset, strings size,
    /// struct size.
    public static let lengthFields = [4, 8, 12, 32, 36]

    public static func word(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) << 24
             | UInt32(bytes[offset + 1]) << 16
             | UInt32(bytes[offset + 2]) << 8
             | UInt32(bytes[offset + 3])
    }

    public static func totalSize(_ bytes: [UInt8]) -> UInt32 { word(bytes, at: 4) }

    /// The furthest byte offset the parser can load from, given this header.
    ///
    /// Derived from the code rather than guessed: `parsePlatformInfo` refuses
    /// the blob unless both blocks end inside `totalsize`, then loads only from
    /// the struct block, from the strings block, and from the 40-byte header.
    /// Property names are read at `off_dt_strings + nameoff` with
    /// `nameoff < size_dt_strings`, so the strings block bounds those too.
    ///
    /// When either block is out of bounds the walk never starts, and the header
    /// is the whole of what was read.
    public static func declaredReach(_ bytes: [UInt8]) -> Int {
        guard bytes.count >= headerSize else { return bytes.count }

        let total       = UInt64(totalSize(bytes))
        let structEnd   = UInt64(word(bytes, at: 8))  + UInt64(word(bytes, at: 36))
        let stringsEnd  = UInt64(word(bytes, at: 12)) + UInt64(word(bytes, at: 32))

        guard structEnd <= total, stringsEnd <= total else { return headerSize }

        return Int(max(UInt64(headerSize), max(structEnd, stringsEnd)))
    }

    /// The live extent of a well-formed blob: the header plus both blocks, and
    /// none of the declared padding behind them.
    public static func liveExtent(_ bytes: [UInt8]) -> Range<Int> {
        headerSize..<max(headerSize + 1, min(declaredReach(bytes), bytes.count))
    }
}


/// Stages a device tree blob in a guarded window sized to what its own header
/// declares, so a load past the declared extent faults instead of being read.
///
/// `.leading` placement is deliberate: the guard has to bound the *declared*
/// blob, since that is the contract the parser works to, and for an untouched
/// QEMU dump the two coincide exactly (`totalsize` is 1 MiB and so is the file)
/// which puts a guard page flush against both ends.
public func withStagedDeviceTree<R>(
    _ blob : [UInt8],
    _ body : (UnsafeRawPointer) -> R
) -> R? {
    withGuardedBlob(blob, declaring: DeviceTreeBlob.declaredReach(blob), placement: .leading) { base, _ in
        body(base)
    }
}


// MARK: - Tar staging

/// Stages a tar archive in a guarded window with its end flush against the
/// trailing guard page, and parks it in `Kernel.platformInfo` for the length of
/// `body`.
///
/// `TarFileSystem` reads the base once at init and re-reads the window on every
/// `isResident` call, so the global is the only way in. Saved and restored here,
/// which is necessary but not sufficient: the suites that call this hold a
/// process-wide global and need `swift test --no-parallel`.
///
/// `.trailing` placement is the whole point. The archive walk only ever steps
/// forward, so putting its last byte on the last readable byte turns "the walk
/// stepped one member past the end" into an immediate fault.
public func withStagedTarArchive<R>(
    _ archive: [UInt8],
    _ body   : (PhysicalAddress, PhysicalAddress) -> R
) -> R? {

    withGuardedBlob(archive, placement: .trailing) { base, count in
        let savedStart = Kernel.platformInfo.initrdStart
        let savedEnd   = Kernel.platformInfo.initrdEnd
        defer {
            Kernel.platformInfo.initrdStart = savedStart
            Kernel.platformInfo.initrdEnd   = savedEnd
        }

        let start = PhysicalAddress(UInt(bitPattern: base))
        let end   = start + UInt64(count)

        Kernel.platformInfo.initrdStart = start
        Kernel.platformInfo.initrdEnd   = end

        return body(start, end)
    }
}
