//
//  ProcessStats.swift
//  ReixOS
//
//  Created by Eliomar on 22/08/2026.
//


/// One process's metrics, filled in for `procStats` sub-operation 1 and
/// republished into the profiler's export page.
///
/// 62 bytes, 64 stride, byte-exact with the kernel writer. `availability`
/// covers the address-space figures only: a process whose address space is
/// already gone reports its identity and leaves them clear.
///
/// Units and accounting domains:
///   * `cpuTime` and `scheduledAt`: generic timer counter units.
///   * `mappedPages`: live translations in *this* address space. Shared, COW
///     and device pages count once per address space that maps them, so a sum
///     across processes is not unique RAM.
///   * `virtualExtentPages`: VMA address-space extent, which reserves nothing.
///   * stack pages: extent is the grow-down VMA's high-water mark, which is
///     also its resident count, and capacity the gap it may still grow into.
///   * `status`: `ProcessStatusCode`.
@frozen
public struct ProcessStats {

    public var pid               : UInt64 = 0 // 0
    public var cpuTime           : UInt64 = 0 // 8
    public var scheduledAt       : UInt64 = 0 // 16
    public var virtualExtentPages: UInt64 = 0 // 24

    public var name: InlineArray<16, UInt8> = .init(repeating: 0) // 32

    public var availability      : UInt32 = 0 // 48
    public var mappedPages       : UInt32 = 0 // 52
    public var stackExtentPages  : UInt16 = 0 // 56
    public var stackCapacityPages: UInt16 = 0 // 58
    public var status            : UInt8  = 0 // 60
    public var nameLength        : UInt8  = 0 // 61

    public init() {}
}


/// Bit assignments for `ProcessStats.availability`.
public enum ProcessMetricAvailability {
    public static let virtualExtent: UInt32 = 1 << 0
    public static let mappedPages  : UInt32 = 1 << 1
    public static let stack        : UInt32 = 1 << 2
}
