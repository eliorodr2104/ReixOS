//
//  MockFileSystem.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


public struct TarFileSystem: FileSystemInterface, Loggable {
    
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
    ) -> Result<FileHandle, FSError> {
        
        guard flags.isDisjoint(with: [.write, .append, .create]) else {
            return .failure(.readOnlyFileSystem)
        }
        
        let findedResult = findFile(path)
        switch findedResult {
            case .success(let entry):

                if let sizeEntry = getFileSize(size: entry.size),
                   isResident(base: entry.address + 512, size: sizeEntry) {

                    if let id = findBucket(
                        address: entry.address + 512,
                        size   : sizeEntry

                    ) { return .success(FileHandle(id: id)) }
                }


            case .failure(let failure):
                return .failure(failure)
        }

        return .failure(.fileNotFound)
    }


    @inline(never)
    public mutating func close(
        handle: FileHandle
    ) -> Result<Void, FSError> {
        guard handle.id >= 0 && handle.id < openedFiles.count else {
            return .failure(.invalidArgument)
        }
        
        openedFiles[handle.id] = OpenFileDescription()
        
        return .success(Void())
    }


    public mutating func read(
        handle: FileHandle,
        buffer: UnsafeMutableRawPointer,
        count : Size
    ) -> Result<Size, FSError> {
        
        guard handle.id >= 0 && handle.id < openedFiles.count else {
            return .failure(.invalidArgument)
        }
        
        let file = openedFiles[handle.id]
        guard file.isUsed else {
            return .failure(.ioError)
        }
        
        guard file.currentOffset <= file.size else {
            return .success(0)
        }
        
        let remainingBytes = file.size - file.currentOffset
        var readBytesSize  = count
        if file.currentOffset + readBytesSize >= file.size {
            readBytesSize = remainingBytes
        }
        
        let source = file.dataPointer! + file.currentOffset
        buffer.copyMemory(from: source, byteCount: readBytesSize)
        
        openedFiles[handle.id].currentOffset += readBytesSize
        
        return .success(readBytesSize)
    }
    
    
    // TODO: Not yet implemented because is only read FS
    public func write(
        handle: FileHandle,
        buffer: UnsafeRawPointer,
        count : Size
    ) -> Result<Size, FSError> {
        .failure(.fileNotFound)
    }
    
    
    public mutating func seek(
           handle: FileHandle,
        to offset: Size,
           method: SeekMethod
    ) -> Result<Size, FSError> {
        
        guard handle.id >= 0 && handle.id < openedFiles.count else {
            return .failure(.invalidArgument)
        }
        
        let file = openedFiles[handle.id]
        guard file.isUsed else {
            return .failure(.ioError)
        }
    
        let newOffset = switch method {
            case .start  :                      offset
            case .current: file.currentOffset + offset
            case .end    : file.size          + offset
        }
        
        guard newOffset <= file.size else {
            return .failure(.invalidArgument)
        }
        
        openedFiles[handle.id].currentOffset = newOffset
        
        return .success(newOffset)
    }



    public func getInfo(path: UnsafePointer<CChar>) -> Result<FileInfo, FSError> {
        let findedResult = findFile(path)
        switch findedResult {
            case .success(let entry):
            
                if let sizeEntry = getFileSize(size: entry.size) {
                    return .success(
                        FileInfo(
                            size       : sizeEntry,
                            isDirectory: false,
                            permissions: 0
                        )
                    )
                }
                
                
            case .failure(let failure):
                return .failure(failure)
        }
        
        return .failure(.fileNotFound)
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
        guard handle.id >= 0 && handle.id < openedFiles.count else {
            return nil
        }

        let file = openedFiles[handle.id]
        guard file.isUsed else {
            return nil
        }

        return file.address
    }


    // MARK: - Helpers

    /// True when `size` bytes at `base` lie entirely inside the initrd image.
    ///
    /// The bound every open handle inherits, and the reason it is taken at `open`
    /// rather than at each use: the size comes from twelve octal digits in a
    /// header this kernel does not author when the archive arrives by `-initrd`,
    /// and one that overruns the archive would hand out a handle whose data
    /// pointer names RAM the initrd never covered. That RAM is frames the buddy
    /// allocator still owns and re-issues, which `read` would copy out of and
    /// `residentBase` would offer up to be mapped into a user address space.
    private func isResident(base: PhysicalAddress, size: Size) -> Bool {
        let archiveStart = Kernel.platformInfo.initrdStart
        let archiveEnd   = Kernel.platformInfo.initrdEnd

        guard archiveEnd > archiveStart, base >= archiveStart, size >= 0 else {
            return false
        }

        let (end, overflow) = base.addingReportingOverflow(UInt64(size))

        return !overflow && end <= archiveEnd
    }


    private mutating func findBucket(
        address: PhysicalAddress,
        size   : Int
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
    
    
    private func findFile(_ path: UnsafePointer<CChar>) -> Result<TarInfo, FSError> {
        var entry = TarInfo(address: tarAddress)

        // The walk is what produces the address `open` then bounds, and a member
        // size it believed could already have stepped it out of the archive.
        while isResident(base: entry.address, size: 512), entry.name?.pointee != 0 {
            
            guard isFileSection(filename: "ustar", entryTar: entry.magic, fieldSize: 6) else {
                return .failure(.fileNotFound)
            }

            if let sizeEntry = getFileSize(size: entry.size) {
                let currentAddress = entry.address
                let sizeAligned = (sizeEntry + 511) & ~511;

                guard isFileSection(filename: path, entryTar: entry.name, fieldSize: 100) else {
                    entry = TarInfo(address: currentAddress + 512 + UInt64(sizeAligned))
                    continue
                }
                
                return .success(entry)
            }
        }
        
        return .failure(.fileNotFound)
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
    
    
    private func getFileSize(size: UnsafePointer<CChar>?) -> Int? {
        guard let size = size else { return nil }
        
        var result: Int = 0;
        for i in 0..<12 {
            let character = size[i];
            if character < 48 || character > 55 { continue }
            result = (result << 3) + Int(character - 48);
        }
        
        return Int(result);
    }
}
