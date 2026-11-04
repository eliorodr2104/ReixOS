//
//  ProgramCopy.swift
//  ReixOS
//

/// Where a copy of a plan's file bytes stands, so it can move one page per step.
public struct ProgramCopy {
    public private(set) var index : Int    = 0
    public private(set) var offset: UInt64 = 0

    public init() {}

    public func isDone(_ plan: ELFLoadPlan) -> Bool {
        var copy = self
        copy.skipFinished(plan)
        return copy.index >= plan.copyCount
    }

    /// Copies the next page; `true` also when there was nothing left.
    /// `false` at a failed read or write.
    public mutating func step<Source: ELFByteSource>(
        _ plan    : ELFLoadPlan,
        from file : inout Source,
        into write: (_ address: UInt64, _ bytes: UnsafeRawPointer, _ count: Int) -> Bool
    ) -> Bool {
        skipFinished(plan)
        if index >= plan.copyCount { return true }
        let copy   = plan.copy(at: index)!
        let wanted = Int(min(copy.byteCount - offset, UInt64(ProgramLoad.chunk)))
        let copied = withUnsafeTemporaryAllocation(byteCount: ProgramLoad.chunk, alignment: 16) { buffer in
            guard let page = buffer.baseAddress,
                  file.read(at: copy.fileOffset + offset, into: page, count: wanted),
                  write(copy.virtualAddress + offset, UnsafeRawPointer(page), wanted)
            else { return false }
            return true
        }
        guard copied else { return false }
        offset += UInt64(wanted)
        skipFinished(plan)
        return true
    }

    private mutating func skipFinished(_ plan: ELFLoadPlan) {
        while index < plan.copyCount, (plan.copy(at: index)?.byteCount ?? 0) <= offset {
            index += 1
            offset = 0
        }
    }
}
