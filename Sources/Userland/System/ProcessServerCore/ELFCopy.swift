//
//  ELFCopy.swift
//  ReixOS
//

import ReixABI

public struct ELFCopy: Equatable {
    public let fileOffset    : UInt64
    public let virtualAddress: UInt64
    public let byteCount     : UInt64

    public init(
        fileOffset    : UInt64,
        virtualAddress: UInt64,
        byteCount     : UInt64
    ) {
        self.fileOffset = fileOffset
        self.virtualAddress = virtualAddress
        self.byteCount = byteCount
    }
}
