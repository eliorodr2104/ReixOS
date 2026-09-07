//
//  ELFLoadRegion.swift
//  ReixOS
//

import ReixABI

public struct ELFLoadRegion: Equatable {
    public let address    : UInt64
    public let pages      : UInt32
    public let permissions: TaskMemoryPermissions

    public init(
        address    : UInt64,
        pages      : UInt32,
        permissions: TaskMemoryPermissions
    ) {
        self.address = address
        self.pages = pages
        self.permissions = permissions
    }
}
