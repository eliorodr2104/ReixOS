//
//  TaskConstruction.swift
//  ReixOS
//

import ReixABI

/// What a suspended task carries only while it is being configured: the
/// regions its owner mapped, which of them are sealed, and whether the entry
/// context is set.
///
/// A heap cell of its own and not part of `TaskRecord`, because the registry's
/// table is static and every slot used to carry this table for the whole life
/// of the task, started or not. It is made at `taskCreate`, charged one frame
/// to the owner's budget, and given back the moment the task leaves
/// `configuring`, whichever way it leaves.
///
/// All-zero is a valid empty construction: the only optional is the budget
/// pointer, whose zero is `nil`, and a zero region is never read past
/// `regionCount`. `ProcessManager.makeConstruction` relies on that to build it
/// in place instead of copying a temporary of this size off the stack.
struct TaskConstruction: RXAllocatable {

    static let errorMessageAllocation: StaticString = "Failed to allocate a task construction"

    /// The owner's budget, charged one frame for this cell and holding one
    /// reference on it, so the refund always has a cell to land in.
    var budget     : UnsafeMutablePointer<FrameBudget>?      // 8 Byte
    var regionCount: UInt8                                    // 1 Byte
    var contextSet : Bool                                     // 1 Byte
    var regions    : InlineArray<32, TaskRegion>              // 768 Byte


    /// Record a mapping the owner just made, writable until it is sealed.
    mutating func append(
        start: VirtualAddress,
        end  : VirtualAddress
    ) -> Bool {
        guard regionCount < UInt8(TaskABI.maximumRegions) else { return false }

        regions[Int(regionCount)] = TaskRegion(
            start      : start,
            end        : end,
            permissions: [.read, .write],
            sealed     : false
        )
        regionCount += 1
        return true
    }


    /// Give the exact region `start..<end` its final permissions, once.
    mutating func seal(
        start      : VirtualAddress,
        end        : VirtualAddress,
        permissions: TaskMemoryPermissions
    ) -> Bool {
        for index in 0..<Int(regionCount) {
            guard regions[index].start == start,
                  regions[index].end == end,
                  !regions[index].sealed
            else { continue }

            regions[index].permissions = permissions
            regions[index].sealed      = true
            return true
        }

        return false
    }


    /// Whether `start..<end` is covered end to end by unsealed writable regions.
    ///
    /// This and the two readers below are `mutating` only so `self` stays
    /// addressable: read through `pointee`, a borrow copied all 784 bytes.
    mutating func permitsWrite(
        start: VirtualAddress,
        end  : VirtualAddress
    ) -> Bool {
        guard end > start else { return false }

        var cursor = start
        while cursor < end {
            var advanced = false

            for index in 0..<Int(regionCount) {
                let region = regions[index]
                guard !region.sealed,
                      region.permissions.contains(.write),
                      region.start <= cursor,
                      cursor < region.end
                else { continue }

                cursor   = region.end < end ? region.end : end
                advanced = true
                break
            }

            if !advanced { return false }
        }

        return true
    }


    /// Whether the entry, stack and break name sealed memory of the right kind.
    mutating func canSetContext(
        entry       : VirtualAddress,
        stack       : VirtualAddress,
        programBreak: VirtualAddress
    ) -> Bool {
        guard stack > UserSpaceLayout.userMin,
              programBreak & (UserSpaceLayout.pageSize - 1) == 0,
              programBreak >= UserSpaceLayout.userMin,
              programBreak <= UserSpaceLayout.mmapMin - UserSpaceLayout.pageSize
        else { return false }

        var entryValid = false
        var stackValid = false
        var imageEnd   = UserSpaceLayout.userMin

        for index in 0..<Int(regionCount) {
            let region = regions[index]
            guard region.sealed else { continue }

            if region.end <= UserSpaceLayout.mmapMin, region.end > imageEnd {
                imageEnd = region.end
            }

            if region.start <= entry, entry < region.end,
               region.permissions.contains(.execute) {
                entryValid = true
            }

            if region.start < stack, stack <= region.end,
               region.permissions.contains(.write),
               !region.permissions.contains(.execute) {
                stackValid = true
            }
        }

        return entryValid && stackValid && programBreak >= imageEnd
    }


    /// A context is set and every region the task holds is sealed.
    var isReady: Bool {
        mutating get {
            guard contextSet, regionCount > 0 else { return false }

            for index in 0..<Int(regionCount) where !regions[index].sealed {
                return false
            }

            return true
        }
    }
}
