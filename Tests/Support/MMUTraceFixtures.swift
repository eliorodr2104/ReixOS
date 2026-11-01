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
    case unknown     = 0
}


/// One recorded call: what it was, its argument, and the descriptor under
/// test as it read at that call.
public struct MMUCall: Equatable, CustomStringConvertible {
    public let op        : MMUOp
    public let arg       : UInt64
    public let descriptor: UInt64

    public init(
        op        : MMUOp,
        arg       : UInt64,
        descriptor: UInt64 = 0
    ) {
        self.op         = op
        self.arg        = arg
        self.descriptor = descriptor
    }

    public var description: String {
        "\(op)(0x\(String(arg, radix: 16)))"
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
