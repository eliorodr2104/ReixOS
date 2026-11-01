//
//  MMUTraceFixtures.swift
//  ReixOS
//

@testable import Kernel
import KernelHostShims

/// The shims `KernelHostShims` records, by the op codes its header assigns.
///
/// One list for every suite that reads the recorder, so a new primitive is
/// classified once and an unknown code reads as `.unknown` instead of as
/// whatever the nearest suite happened to fall back to.
public enum MMUOp: UInt32, Equatable {
    case barrier     = 1
    case tlbSync     = 4
    case tlbAll      = 5
    case isb         = 6
    case tlbASID     = 7
    case tlbLeaf     = 8
    case tlbTable    = 9
    case cleanPoU    = 10
    case icacheLines = 11
    case icacheAll   = 12
    case stream      = 13
    case unknown     = 0
}


/// One recorded call: what it was, its argument, the range it covered and the
/// line it stepped by, and the descriptor under test as it read at that call.
public struct MMUCall: Equatable, CustomStringConvertible {
    public let op        : MMUOp
    public let arg       : UInt64
    public let size      : UInt64
    public let line      : UInt64
    public let descriptor: UInt64

    public init(
        op        : MMUOp,
        arg       : UInt64,
        size      : UInt64 = 0,
        line      : UInt64 = 0,
        descriptor: UInt64 = 0
    ) {
        self.op         = op
        self.arg        = arg
        self.size       = size
        self.line       = line
        self.descriptor = descriptor
    }

    public var description: String {
        "\(op)(0x\(String(arg, radix: 16)), size \(size), line \(line))"
    }
}


/// The recorder since the last `mmu_trace_reset`, in call order.
public func mmuCalls() -> [MMUCall] {
    var calls: [MMUCall] = []
    var index: UInt64 = 0

    while index < mmu_trace_length() {
        calls.append(MMUCall(
            op        : MMUOp(rawValue: mmu_trace_op(index)) ?? .unknown,
            arg       : mmu_trace_arg(index),
            size      : mmu_trace_size(index),
            line      : mmu_trace_line(index),
            descriptor: mmu_trace_descriptor(index)
        ))
        index += 1
    }

    return calls
}


/// The recorder's op codes alone, for a suite that asserts the shape first.
public func mmuOps() -> [MMUOp] { mmuCalls().map(\.op) }


/// How many recorded calls were `op`.
public func mmuCount(_ op: MMUOp) -> Int { mmuOps().filter { $0 == op }.count }


/// The operand a by-address invalidation of `virtual` under `asid` hands the
/// hardware, which is what the shim records: VA[55:12] and the tag in [63:48].
public func tlbiOperand(_ virtual: VirtualAddress, asid: ASID) -> UInt64 {
    ((virtual >> 12) & ((1 << 44) - 1)) | (UInt64(asid) << 48)
}


/// CTR_EL0 of the machine `make run` boots, QEMU's Cortex-A53: 64-byte lines on
/// both sides, a VIPT instruction cache, and neither IDC nor DIC.
public let cortexA53CacheType: UInt64 = 0x8444_8004


/// Runs `body` with `cacheType` loaded the way boot loads it, through the shim's
/// CTR_EL0, and puts both back afterwards.
public func withCacheType<Result>(
    _ value: UInt64,
    _ body : () throws -> Result
) rethrows -> Result {
    let saved = Arch.MMU.cacheType

    host_set_cache_type(value)
    Arch.MMU.loadCacheType()

    defer {
        Arch.MMU.cacheType = saved
        host_set_cache_type(0)
    }

    return try body()
}
