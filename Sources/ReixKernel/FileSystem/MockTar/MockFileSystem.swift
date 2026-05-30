//
//  MockFileSystem.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

internal struct OpenFileDescription {
    let dataPointer  : UnsafeRawPointer
    let size         : Size
    var currentOffset: Size
    let isUsed       : Bool
}


public struct MockFileSystem: FileSystemInterface {
    
    let tarAddress = Kernel.platformInfo.initrdStart
    
    public func open(
        path : String,
        flags: FileFlags
    ) -> Result<FileHandle, FSError> {
        return .success(FileHandle(id: 0))
    }
    
    public func close(
        handle: FileHandle
    ) -> Result<Void, FSError> {
        .failure(.fileNotFound)
    }


    public func read(
        handle: FileHandle,
        buffer: UnsafeMutableRawPointer,
        count : Size
    ) -> Result<Size, FSError> {
        .failure(.fileNotFound)
    }
    
    public func write(
        handle: FileHandle,
        buffer: UnsafeRawPointer,
        count : Size
    ) -> Result<Size, FSError> {
        .failure(.fileNotFound)
    }
    
    public func seek(
           handle: FileHandle,
        to offset: Size,
           method: SeekMethod
    ) -> Result<Size, FSError> {
        .failure(.fileNotFound)
    }



    public func getInfo(path: StaticString) -> Result<FileInfo, FSError> {
        var entry = TarInfo(address: tarAddress)
        while entry.name?.pointee != 0 {
            
            guard isFileSection(filename: "ustar", entryTar: entry.magic) else {
                return .failure(.fileNotFound)
            }
            
            let size = getFileSize(size: entry.size);
            switch size {
                case .success(let success):
                    let currentAddress = entry.address
                    let sizeAligned = (success + 511) & ~511;
                
                    guard isFileSection(filename: path, entryTar: entry.name) else {
                        entry = TarInfo(address: currentAddress + 512 + UInt64(sizeAligned))
                        continue
                    }
                
                    return .success(
                        FileInfo(
                            size: UInt64(success),
                            isDirectory: false,
                            permissions: 0
                        )
                    )
                    
                case .failure(let failure):
                    return .failure(failure)
            }
        }
        
        return .failure(.fileNotFound)
    }
    
    
    private func isFileSection(
        filename: StaticString,
        entryTar: UnsafePointer<CChar>?
    ) -> Bool{

        var current = UnsafeRawPointer(
            filename.utf8Start
        ).assumingMemoryBound(to: CChar.self)
        
        var result       = true
        var iteratorName = 0
        
        while current.pointee != 0 && result {
            
            if (current.pointee != entryTar?.advanced(by: iteratorName).pointee) {
                result = false
                break
            }
            
            iteratorName += 1
            current = current.advanced(by: 1)
        }
        
        return result
    }
    
    
    private func getFileSize(size: UnsafePointer<CChar>?) -> Result<Int, FSError> {
        guard let size = size else { return .failure(.ioError) }
        
        var result: Int = 0;
        for i in 0..<12 {
            let character = size.advanced(by: i).pointee;
            if character < 48 || character > 55 { continue }
            result = (result << 3) + Int(character - 48);
        }
        
        return .success(Int(result));
    }
}
