//
//  MockFileSystem.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


public struct TarFileSystem: FileSystemInterface {
    
    public static var errorMessageAllocation = "Failed to allocate TarFileSystem on the kernel heap"
        
    let tarAddress : VirtualAddress = Kernel.platformInfo.initrdStart
    var openedFiles: InlineArray<32, OpenFileDescription>
            
    init() {
        self.openedFiles = InlineArray(repeating: OpenFileDescription())
    }
    
    
    public mutating func open(
        path : UnsafePointer<CChar>,
        flags: FileFlags
    ) -> Result<FileHandle, FSError> {
        guard !flags.contains(.write) else {
            return .failure(.readOnlyFileSystem)
        }
        
        let findedResult = findFile(path)
        switch findedResult {
            case .success(let entry):
            
                if let sizeEntry = getFileSize(size: entry.size) {
                    
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
        
        var file = openedFiles[handle.id]
        guard file.isUsed else {
            return .failure(.ioError)
        }
    
        let newOffset = switch method {
            case .start  :                              offset
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
    
    
    // MARK: - Helpers
    
    private mutating func findBucket(
        address: VirtualAddress,
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
        while entry.name?.pointee != 0 {
            
            guard isFileSection(filename: "ustar", entryTar: entry.magic) else {
                return .failure(.fileNotFound)
            }
            
            if let sizeEntry = getFileSize(size: entry.size) {
                let currentAddress = entry.address
                let sizeAligned = (sizeEntry + 511) & ~511;
            
                guard isFileSection(filename: path, entryTar: entry.name) else {
                    entry = TarInfo(address: currentAddress + 512 + UInt64(sizeAligned))
                    continue
                }
                
                return .success(entry)
            }
        }
        
        return .failure(.fileNotFound)
    }
    
    
    private func isFileSection(
        filename: UnsafePointer<CChar>,
        entryTar: UnsafePointer<CChar>?
    ) -> Bool{
        
        guard let entryTar = entryTar else { return false }

        var current      = filename
        var result       = true
        var iteratorName = 0
        
        while current.pointee != 0 && result {
            
            if (current.pointee != entryTar[iteratorName]) {
                result = false
                break
            }
            
            iteratorName += 1
            current = current.advanced(by: 1)
        }
        
        return result
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
