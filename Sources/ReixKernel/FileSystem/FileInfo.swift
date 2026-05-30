//
//  FileInfo.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


public struct FileInfo {
    public let size       : Size
    public let isDirectory: Bool
    public let permissions: UInt16
    
    public init(
        size       : Size,
        isDirectory: Bool,
        permissions: UInt16
    ) {
        self.size        = size
        self.isDirectory = isDirectory
        self.permissions = permissions
    }
}