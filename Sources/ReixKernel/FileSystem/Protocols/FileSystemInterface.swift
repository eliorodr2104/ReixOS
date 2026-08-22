//
//  FileSystemInterface.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

public typealias Size = Int

public protocol FileSystemInterface: RXAllocatable {
    
    mutating func open(
        path : UnsafePointer<CChar>,
        flags: FileFlags
    ) -> Result<FileHandle, FSError>
    
    mutating func close(
        handle: FileHandle
    ) -> Result<Void, FSError>


    mutating func read(
        handle: FileHandle,
        buffer: UnsafeMutableRawPointer,
        count : Size
    ) -> Result<Size, FSError>
    
    func write(
        handle: FileHandle,
        buffer: UnsafeRawPointer,
        count : Size
    ) -> Result<Size, FSError>
    
    mutating func seek(
           handle: FileHandle,
        to offset: Size,
           method: SeekMethod
    ) -> Result<Size, FSError>



    func getInfo(path: UnsafePointer<CChar>) -> Result<FileInfo, FSError>


    /// Physical/identity base of an open handle's resident data, for
    /// filesystems whose pages stay pinned in place (e.g. an initrd).
    /// Returns nil for a closed/unused handle or when no such guarantee exists.
    mutating func residentBase(handle: FileHandle) -> PhysicalAddress?
}


public extension FileSystemInterface {

    /// Default for filesystems that cannot promise a stable physical base;
    /// returning nil here keeps them honest instead of forcing a made-up value.
    mutating func residentBase(handle: FileHandle) -> PhysicalAddress? {
        nil
    }
}
