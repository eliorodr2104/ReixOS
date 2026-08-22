//
//  KernelDeadlineQueue.swift
//  ReixOS
//
//  Created by Eliomar on 22/08/2026.
//

struct KernelDeadlineQueue {
    // A live process owns at least one 4 KiB root-table frame. On the 4 MiB
    // target, 1024 is therefore a hard upper bound even before kernel memory.
    static let capacity = 1024
    static let tickBudget = 8

    static var shared = KernelDeadlineQueue()

    private var heap = InlineArray<1024, UnsafeMutablePointer<Process>?>(repeating: nil)
    private(set) var count = 0
    private var nextOrder: UInt64 = 0
    
    #if !hasFeature(Embedded)
    private(set) var inspectionCount: UInt64 = 0
    #endif

    @inline(__always)
    func hasDue(at now: UInt64) -> Bool {
        guard count > 0, let first = heap[0] else { return false }
        return Self.isDue(first.pointee.kernelDeadline, at: now)
    }

    @discardableResult
    mutating func arm(
        _ process : UnsafeMutablePointer<Process>,
          kind    : KernelDeadlineKind,
          deadline: UInt64
    ) -> Bool {
        guard kind != .none else { return false }

        if process.pointee.kernelDeadlineKind != .none {
            _ = cancel(process)
        }

        guard count < Self.capacity else { return false }

        let index = count
        count += 1

        process.pointee.kernelDeadline      = deadline
        process.pointee.kernelDeadlineOrder = nextOrder
        process.pointee.kernelDeadlineKind  = kind
        process.pointee.kernelDeadlineIndex = UInt16(index)
        nextOrder &+= 1

        heap[index] = process
        siftUp(from: index)
        return true
    }

    @discardableResult
    mutating func cancel(_ process: UnsafeMutablePointer<Process>) -> Bool {
        guard process.pointee.kernelDeadlineKind != .none else { return false }

        let index = Int(process.pointee.kernelDeadlineIndex)
        guard index < count, heap[index] == process else {
            clear(process)
            return false
        }

        remove(at: index)
        return true
    }

    @discardableResult
    mutating func poll(
          now   : UInt64,
          budget: Int,
        _ body  : (UnsafeMutablePointer<Process>, KernelDeadlineKind) -> Void
    ) -> Int {
        guard budget > 0 else { return 0 }

        var expired = 0
        while expired < budget, count > 0, let first = heap[0] {
            #if !hasFeature(Embedded)
            inspectionCount &+= 1
            #endif
            
            guard Self.isDue(first.pointee.kernelDeadline, at: now) else { break }

            let kind = first.pointee.kernelDeadlineKind
            remove(at: 0)
            body(first, kind)
            expired += 1
        }

        return expired
    }

    #if !hasFeature(Embedded)
    mutating func resetInspectionCount() {
        inspectionCount = 0
    }
    #endif

    @inline(__always)
    private static func isDue(_ deadline: UInt64, at now: UInt64) -> Bool {
        Int64(bitPattern: now &- deadline) >= 0
    }

    @inline(__always)
    private static func precedes(
        _ lhs: UnsafeMutablePointer<Process>,
        _ rhs: UnsafeMutablePointer<Process>
    ) -> Bool {
        let lhsDeadline = lhs.pointee.kernelDeadline
        let rhsDeadline = rhs.pointee.kernelDeadline

        if lhsDeadline != rhsDeadline {
            return Int64(bitPattern: lhsDeadline &- rhsDeadline) < 0
        }

        let lhsOrder = lhs.pointee.kernelDeadlineOrder
        let rhsOrder = rhs.pointee.kernelDeadlineOrder
        if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }

        return lhs.pointee.pid < rhs.pointee.pid
    }

    private mutating func remove(at index: Int) {
        let removed = heap[index]!
        let lastIndex = count - 1
        count = lastIndex

        if index != lastIndex {
            let replacement = heap[lastIndex]!
            heap[index] = replacement
            replacement.pointee.kernelDeadlineIndex = UInt16(index)
        }

        heap[lastIndex] = nil
        clear(removed)

        guard index < count else { return }

        if index > 0 {
            let parent = (index - 1) / 2
            if Self.precedes(heap[index]!, heap[parent]!) {
                siftUp(from: index)
                return
            }
        }

        siftDown(from: index)
    }

    private mutating func siftUp(from start: Int) {
        var child = start

        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.precedes(heap[child]!, heap[parent]!) else { return }

            swap(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from start: Int) {
        var parent = start

        while true {
            let left = parent * 2 + 1
            guard left < count else { return }

            let right = left + 1
            var child = left
            if right < count, Self.precedes(heap[right]!, heap[left]!) {
                child = right
            }

            guard Self.precedes(heap[child]!, heap[parent]!) else { return }

            swap(parent, child)
            parent = child
        }
    }

    @inline(__always)
    private mutating func swap(_ lhs: Int, _ rhs: Int) {
        let left = heap[lhs]!
        let right = heap[rhs]!

        heap[lhs] = right
        heap[rhs] = left
        right.pointee.kernelDeadlineIndex = UInt16(lhs)
        left.pointee.kernelDeadlineIndex = UInt16(rhs)
    }

    @inline(__always)
    private func clear(_ process: UnsafeMutablePointer<Process>) {
        process.pointee.kernelDeadline      = 0
        process.pointee.kernelDeadlineOrder = 0
        process.pointee.kernelDeadlineKind  = .none
        process.pointee.kernelDeadlineIndex = .max
    }
}
