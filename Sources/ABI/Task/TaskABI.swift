//
//  TaskABI.swift
//  ReixOS
//

public enum TaskABI {
    public static let pageSize              : UInt64 = 4096
    public static let maximumRegions        : UInt32 = 32
    public static let maximumPagesPerMapping: UInt32 = 1024
    public static let maximumWriteBytes     : UInt64 = 64 * 1024

    /// Shared task-loader view of the user address-space contract.
    public static let userMin    : UInt64 = 0x0000_0080_0000_0000
    public static let userMax    : UInt64 = 0x0000_7FFF_FFFF_F000
    public static let programBase: UInt64 = 0x0000_0080_0040_0000
    public static let heapLimit  : UInt64 = 0x0000_0080_2000_0000
    public static let stackTop   : UInt64 = 0x0000_0080_3FFF_E000
    public static let stackLimit : UInt64 = 0x0000_0080_3C00_0000
}
