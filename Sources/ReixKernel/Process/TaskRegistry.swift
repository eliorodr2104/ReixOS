//
//  TaskRegistry.swift
//  ReixOS
//

import ReixABI

enum TaskRegistry {
    static let capacity = 32

    private static var records     = InlineArray<32, TaskRecord?>(repeating: nil)
    private static var generations = InlineArray<32, UInt32>(repeating: 0)

    static func create(
        owner  : Identity,
        process: UnsafeMutablePointer<Process>
    ) -> TaskControl? {
        for index in 0..<records.count where records[index] == nil {
            var generation = generations[index] &+ 1
            if generation == 0 { generation = 1 }
            generations[index] = generation

            let control = TaskControl(slot: UInt8(index), generation: generation)
            records[index] = TaskRecord(
                control: control,
                owner: owner,
                process: process
            )
            return control
        }

        return nil
    }

    static func record(_ control: TaskControl) -> TaskRecord? {
        let index = Int(control.slot)
        guard index < records.count,
              let record = records[index],
              record.control == control
        else { return nil }

        return record
    }

    static func isOwned(
        _ control  : TaskControl,
        by identity: Identity
    ) -> Bool {
        record(control)?.owner == identity
    }

    @discardableResult
    static func update(
        _ control: TaskControl,
        _ body   : (inout TaskRecord) -> Bool
    ) -> Bool {
        let index = Int(control.slot)
        guard index < records.count,
              var record = records[index],
              record.control == control
        else { return false }

        let result = body(&record)
        records[index] = record
        return result
    }

    static func retain(_ control: TaskControl) {
        _ = update(control) { record in
            guard record.capabilityReferences < UInt16.max else { return false }
            record.capabilityReferences += 1
            return true
        }
    }

    static func release(_ control: TaskControl) {
        let index = Int(control.slot)
        guard index < records.count,
              var record = records[index],
              record.control == control,
              record.capabilityReferences > 0
        else { return }

        record.capabilityReferences -= 1
        records[index] = record
        collectIfUnused(control)
    }

    static func appendRegion(
        _ control: TaskControl,
        start    : VirtualAddress,
        end      : VirtualAddress
    ) -> Bool {
        update(control) { record in
            guard case .configuring = record.lifecycle,
                  record.regionCount < UInt8(TaskABI.maximumRegions)
            else { return false }

            let index = Int(record.regionCount)
            record.regions[index] = TaskRegion(
                start: start,
                end: end,
                permissions: [.read, .write],
                sealed: false
            )
            record.regionCount += 1
            return true
        }
    }

    static func sealRegion(
        _ control  : TaskControl,
        start      : VirtualAddress,
        end        : VirtualAddress,
        permissions: TaskMemoryPermissions
    ) -> Bool {
        update(control) { record in
            guard case .configuring = record.lifecycle else { return false }

            for index in 0..<Int(record.regionCount) {
                guard var region = record.regions[index],
                      region.start == start,
                      region.end == end,
                      !region.sealed
                else { continue }

                region.permissions = permissions
                region.sealed = true
                record.regions[index] = region
                return true
            }

            return false
        }
    }

    static func permitsWrite(
        _ control: TaskControl,
        start    : VirtualAddress,
        end      : VirtualAddress
    ) -> Bool {
        guard let record = record(control),
              case .configuring = record.lifecycle,
              end > start
        else { return false }

        var cursor = start
        while cursor < end {
            var advanced = false

            for index in 0..<Int(record.regionCount) {
                guard let region = record.regions[index],
                      !region.sealed,
                      region.permissions.contains(.write),
                      region.start <= cursor,
                      cursor < region.end
                else { continue }

                cursor = region.end < end ? region.end : end
                advanced = true
                break
            }

            if !advanced { return false }
        }

        return true
    }

    static func canSetContext(
        _ control   : TaskControl,
        entry       : VirtualAddress,
        stack       : VirtualAddress,
        programBreak: VirtualAddress
    ) -> Bool {
        guard let record = record(control),
              case .configuring = record.lifecycle,
              stack > UserSpaceLayout.userMin,
              programBreak & (UserSpaceLayout.pageSize - 1) == 0,
              programBreak >= UserSpaceLayout.userMin,
              programBreak <= UserSpaceLayout.mmapMin - UserSpaceLayout.pageSize
        else { return false }

        var entryValid = false
        var stackValid = false
        var imageEnd   = UserSpaceLayout.userMin

        for index in 0..<Int(record.regionCount) {
            guard let region = record.regions[index], region.sealed else { continue }

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

    static func markContextSet(_ control: TaskControl) -> Bool {
        update(control) { record in
            guard case .configuring = record.lifecycle else { return false }
            record.contextSet = true
            return true
        }
    }

    static func readyToStart(_ control: TaskControl) -> Bool {
        guard let record = record(control),
              case .configuring = record.lifecycle,
              record.contextSet,
              record.regionCount > 0
        else { return false }

        for index in 0..<Int(record.regionCount) {
            guard record.regions[index]?.sealed == true else { return false }
        }

        return true
    }

    static func markRunning(_ control: TaskControl) -> Bool {
        update(control) { record in
            guard case .configuring = record.lifecycle else { return false }
            record.lifecycle = .running
            return true
        }
    }

    static func markExited(
        _ control: TaskControl,
        code     : ExitCode
    ) {
        _ = update(control) { record in
            record.lifecycle = .exited(code)
            return true
        }
    }

    static func markAborted(_ control: TaskControl) {
        _ = update(control) { record in
            record.lifecycle = .aborted
            return true
        }
    }

    static func markProcessGone(_ control: TaskControl) {
        _ = update(control) { record in
            record.process = nil
            return true
        }
        collectIfUnused(control)
    }

    static func status(_ control: TaskControl) -> (TaskState, ExitCode) {
        guard let record = record(control) else { return (.invalid, 0) }

        switch record.lifecycle {
            case .configuring: return (.configuring, 0)
            case .running: return (.running, 0)
            case .exited(let code): return (.exited, code)
            case .aborted: return (.aborted, 0)
        }
    }

    static func controls(ownedBy identity: Identity) -> InlineArray<32, TaskControl?> {
        var result = InlineArray<32, TaskControl?>(repeating: nil)
        var count  = 0

        for index in 0..<records.count {
            guard let record = records[index], record.owner == identity else { continue }
            result[count] = record.control
            count += 1
        }

        return result
    }

    private static func collectIfUnused(_ control: TaskControl) {
        let index = Int(control.slot)
        guard index < records.count,
              let record = records[index],
              record.control == control,
              record.capabilityReferences == 0,
              record.process == nil
        else { return }

        switch record.lifecycle {
            case .exited, .aborted:
                records[index] = nil
            case .configuring, .running:
                break
        }
    }

    #if !hasFeature(Embedded)
    static func resetForTesting() {
        records = InlineArray<32, TaskRecord?>(repeating: nil)
        generations = InlineArray<32, UInt32>(repeating: 0)
    }
    #endif
}
