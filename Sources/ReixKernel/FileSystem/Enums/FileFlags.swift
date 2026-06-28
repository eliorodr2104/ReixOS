//
//  FileFlags.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


public struct FileFlags: OptionSet {
    public let  rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let read   = FileFlags(rawValue: 1 << 0)
    public static let write  = FileFlags(rawValue: 1 << 1)
    public static let append = FileFlags(rawValue: 1 << 1)
    public static let create = FileFlags(rawValue: 1 << 1)
}