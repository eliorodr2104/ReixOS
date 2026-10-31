//
//  MockFileSystem.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


/// The initrd as a read-only file system.
///
/// Offsets, sizes and counts are `UInt64` and every failure is a typed
/// `FSError`, so a negative position cannot be expressed and a refusal cannot
/// be dropped by forgetting to look at a `Result`. A member is only handed out
/// after its header has passed the checksum, its size field has parsed as
/// octal and its data has been shown to lie inside the archive window.
public struct TarFileSystem: RXAllocatable, Loggable {
    
    public static var errorMessageAllocation: StaticString = "Failed to allocate TarFileSystem on the kernel heap"
    
    public static let nameLog : StaticString = "[FS  ]"
    public static let logLevel: LogLevel     = .info
        
    var openedFiles = InlineArray<32, OpenFileDescription>(repeating: OpenFileDescription())
    let tarAddress  = Kernel.platformInfo.initrdStart


    /// Written out rather than left implicit only so the boot line has
    /// somewhere to live. Everything it initialises still comes from the
    /// property declarations above.
    public init() {
        Self.boot("Internal File System ready.")
    }


    @inline(never)
    public mutating func open(
        path : UnsafePointer<CChar>,
        flags: FileFlags
    ) throws(FSError) -> FileHandle {
        
        guard flags.isDisjoint(with: [.write, .append, .create]) else {
            throw .readOnlyFileSystem
        }

        let member = try findFile(path)

        guard let id = findBucket(address: member.data, size: member.size) else {
            throw .fileNotFound
        }

        return FileHandle(id: id)
    }


    /// Refuses a slot that is not open, so a second `close` is an error rather
    /// than a silent rewrite of a slot another `open` may already own.
    @inline(never)
    public mutating func close(
        handle: FileHandle
    ) throws(FSError) {
        let slot = try usedSlot(handle)

        openedFiles[slot] = OpenFileDescription()
    }


    /// Copies `min(count, bytes left)` bytes and advances by that many, so a
    /// read at or past the end returns 0 and no sum of offset and count is
    /// ever formed.
    public mutating func read(
        handle: FileHandle,
        buffer: UnsafeMutableRawPointer,
        count : UInt64
    ) throws(FSError) -> UInt64 {

        let slot = try usedSlot(handle)
        let file = openedFiles[slot]

        // Holds by construction; checked so a broken `seek` is an error here and
        // not a subtraction that traps.
        guard file.currentOffset <= file.size else { throw .ioError }

        let readBytesSize = min(count, file.size - file.currentOffset)

        // Both fit an `Int`: `findFile` bounded the member by the archive window.
        let source = file.dataPointer! + Int(clamping: file.currentOffset)
        buffer.copyMemory(from: source, byteCount: Int(clamping: readBytesSize))

        openedFiles[slot].currentOffset = file.currentOffset + readBytesSize

        return readBytesSize
    }
    
    
    /// Exists only to say no: the initrd is read-only, and `open` already
    /// refuses the flags that would have produced a writable handle.
    public func write(
        handle: FileHandle,
        buffer: UnsafeRawPointer,
        count : UInt64
    ) throws(FSError) -> UInt64 {
        throw .readOnlyFileSystem
    }
    
    
    /// Absolute only. A relative or from-the-end seek with an unsigned offset
    /// can never land inside the member, so those modes would be dead weight,
    /// and the size is asked for directly with `size(handle:)`.
    public mutating func seek(
           handle: FileHandle,
        to offset: UInt64
    ) throws(FSError) {

        let slot = try usedSlot(handle)

        guard offset <= openedFiles[slot].size else { throw .invalidArgument }

        openedFiles[slot].currentOffset = offset
    }


    /// Size of the member behind `handle`.
    public mutating func size(handle: FileHandle) throws(FSError) -> UInt64 {
        openedFiles[try usedSlot(handle)].size
    }



    public func getInfo(path: UnsafePointer<CChar>) throws(FSError) -> FileInfo {
        let member = try findFile(path)

        return FileInfo(
            size       : member.size,
            isDirectory: false,
            permissions: 0
        )
    }


    /// Every open handle already points straight into the initrd image, so
    /// this is a lookup, not new machinery: just expose the resident base.
    ///
    /// `mutating` despite mutating nothing, and not `borrowing` either: reading
    /// `openedFiles[i]` goes through `InlineArray`'s read accessor, which the
    /// compiler models as a coroutine. Without an addressable `self` it cannot
    /// borrow through that, so it copies the whole 1032-byte struct into the
    /// caller's frame first. Measured: 1024 bytes of kernel stack on the spawn
    /// path, on a method that returns one word. `borrowing` is rejected outright
    /// here ("self cannot be captured by an escaping closure").
    public mutating func residentBase(handle: FileHandle) -> PhysicalAddress? {
        guard let slot = try? usedSlot(handle) else { return nil }

        return openedFiles[slot].address
    }


    // MARK: - Helpers

    /// Index of `handle`'s slot, refusing one outside the table or not open.
    private mutating func usedSlot(_ handle: FileHandle) throws(FSError) -> Int {
        guard handle.id >= 0 && handle.id < openedFiles.count else {
            throw .invalidArgument
        }

        guard openedFiles[handle.id].isUsed else { throw .ioError }

        return handle.id
    }


    /// True when `size` bytes at `base` lie entirely inside the initrd image.
    ///
    /// The bound every open handle inherits, and the reason it is taken when the
    /// member is found rather than at each use: the size comes from twelve octal
    /// digits in a header this kernel does not author when the archive arrives
    /// by `-initrd`, and one that overruns the archive would hand out a handle
    /// whose data pointer names RAM the initrd never covered. That RAM is frames
    /// the buddy allocator still owns and re-issues, which `read` would copy out
    /// of and `residentBase` would offer up to be mapped into a user address
    /// space.
    private func isResident(base: PhysicalAddress, size: UInt64) -> Bool {
        let archiveStart = Kernel.platformInfo.initrdStart
        let archiveEnd   = Kernel.platformInfo.initrdEnd

        guard archiveEnd > archiveStart, base >= archiveStart else {
            return false
        }

        let (end, overflow) = base.addingReportingOverflow(size)

        return !overflow && end <= archiveEnd
    }


    private mutating func findBucket(
        address: PhysicalAddress,
        size   : UInt64
    ) -> Int? {
        
        var idBucket: Int?
        for i in 0..<32 {
            
            if !openedFiles[i].isUsed {
                
                openedFiles[i] = OpenFileDescription(
                    address      : address,
                    size         : size,
                    currentOffset: 0,
                    isUsed       : true
                )

                idBucket = i
                break
            }
        }
        
        return idBucket
    }
    
    
    /// The data address and length of the member called `path`, whose data is
    /// known to lie inside the archive.
    ///
    /// Every header on the way is checked before its size is believed, because
    /// the size is what the walk steps by: one that is not octal, or sits in a
    /// block whose checksum fails, ends the lookup with `.ioError` instead of
    /// sending the walk to wherever the damaged digits point. So does a target
    /// whose data would run past the archive. A header that is not ustar at all
    /// still ends it as `.fileNotFound`, as trailing bytes do.
    private func findFile(
        _ path: UnsafePointer<CChar>
    ) throws(FSError) -> (data: PhysicalAddress, size: UInt64) {

        var entry = TarInfo(address: tarAddress)

        // The walk is what produces the address `open` then bounds, and a member
        // size it believed could already have stepped it out of the archive.
        while isResident(base: entry.address, size: UInt64(TarInfo.blockSize)),
              entry.name?.pointee != 0 {
            
            guard isFileSection(filename: "ustar", entryTar: entry.magic, fieldSize: 6) else {
                throw .fileNotFound
            }

            guard entry.hasValidChecksum, let size = entry.contentSize else {
                throw .ioError
            }

            let data = entry.address + UInt64(TarInfo.blockSize)

            if isFileSection(filename: path, entryTar: entry.name, fieldSize: 100) {
                guard isResident(base: data, size: size) else { throw .ioError }

                return (data, size)
            }

            let (padded, sizeOverflow) = size.addingReportingOverflow(511)
            let (next  , nextOverflow) = data.addingReportingOverflow(padded & ~511)
            guard !sizeOverflow, !nextOverflow else { throw .ioError }

            entry = TarInfo(address: next)
        }
        
        throw .fileNotFound
    }
    
    
    private func isFileSection(
        filename : UnsafePointer<CChar>,
        entryTar : UnsafePointer<CChar>?,
        fieldSize: Int
    ) -> Bool{

        guard let entryTar = entryTar else { return false }

        var current      = filename
        var result       = true
        var iteratorName = 0

        while current.pointee != 0 && result {

            guard iteratorName < fieldSize, current.pointee == entryTar[iteratorName] else {
                result = false
                break
            }

            iteratorName += 1
            current = current.advanced(by: 1)
        }

        // A prefix is not a match: the member name must end exactly here,
        // either at a NUL or by filling the whole fixed-width field.
        return result && (iteratorName == fieldSize || entryTar[iteratorName] == 0)
    }
}
