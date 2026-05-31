//
//  FileSystemInterface.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

public typealias Size = Int

public protocol FileSystemInterface: RXObject {
    
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
}
