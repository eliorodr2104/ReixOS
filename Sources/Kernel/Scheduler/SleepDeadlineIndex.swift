//
//  SleepDeadlineIndex.swift
//  ReixOS
//
//  Created by Eliomar on 22/08/2026.
//

struct SleepDeadlineIndex {
    static let capacity = 32
    private static let slotCount = 64

    private enum SlotState: UInt8 {
        case empty
        case occupied
        case tombstone
    }

    private struct Slot {
        var process: UnsafeMutablePointer<Process>? = nil
        var state: SlotState = .empty
    }

    private var slots = InlineArray<64, Slot>(repeating: Slot())
    private(set) var count = 0

    mutating func insert(_ process: UnsafeMutablePointer<Process>) -> Bool {
        guard count < Self.capacity else { return false }

        let start = hash(process.pointee.pid)
        var firstTombstone: Int? = nil

        for offset in 0..<Self.slotCount {
            let index = (start + offset) & (Self.slotCount - 1)

            switch slots[index].state {
                case .occupied:
                    if slots[index].process?.pointee.pid == process.pointee.pid {
                        return false
                    }

                case .tombstone:
                    if firstTombstone == nil { firstTombstone = index }

                case .empty:
                    occupy(firstTombstone ?? index, with: process)
                    return true
            }
        }

        guard let firstTombstone else { return false }
        occupy(firstTombstone, with: process)
        return true
    }

    mutating func remove(pid: PID) -> UnsafeMutablePointer<Process>? {
        let start = hash(pid)

        for offset in 0..<Self.slotCount {
            let index = (start + offset) & (Self.slotCount - 1)

            switch slots[index].state {
                case .empty:
                    return nil

                case .occupied:
                    guard let process = slots[index].process,
                          process.pointee.pid == pid else {
                        continue
                    }

                    slots[index].process = nil
                    slots[index].state = .tombstone
                    count -= 1
                    return process

                case .tombstone:
                    continue
            }
        }

        return nil
    }

    @inline(__always)
    private func hash(_ pid: PID) -> Int {
        let mixed = pid &* 0x9E37_79B9_7F4A_7C15
        return Int(truncatingIfNeeded: mixed >> 58)
    }

    @inline(__always)
    private mutating func occupy(
        _ index: Int,
        with process: UnsafeMutablePointer<Process>
    ) {
        slots[index].process = process
        slots[index].state = .occupied
        count += 1
    }
}
