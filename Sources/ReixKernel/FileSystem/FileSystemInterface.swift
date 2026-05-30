//
//  FileSystemInterface.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

public typealias Size = UInt64

public protocol FileSystemInterface {
    
    func open(
        path : String,
        flags: FileFlags
    ) -> Result<FileHandle, FSError>
    
    func close(
        handle: FileHandle
    ) -> Result<Void, FSError>


    func read(
        handle: FileHandle,
        buffer: UnsafeMutableRawPointer,
        count : Size
    ) -> Result<Size, FSError>
    
    func write(
        handle: FileHandle,
        buffer: UnsafeRawPointer,
        count : Size
    ) -> Result<Size, FSError>
    
    func seek(
           handle: FileHandle,
        to offset: Size,
           method: SeekMethod
    ) -> Result<Size, FSError>



    func getInfo(path: StaticString) -> Result<FileInfo, FSError>
}
