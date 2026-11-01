//
//  TaskRegistry.swift
//  ReixOS
//

import ReixABI

/// Every task token the kernel has handed out, by slot.
///
/// Only the compact live record is static. Reads and writes go to the slot in
/// place: no operation copies a record out to change one field and back.
enum TaskRegistry {
    static let capacity = 32

    private static var records     = InlineArray<32, TaskRecord?>(repeating: nil)
    private static var generations = InlineArray<32, UInt32>(repeating: 0)

    static func create(
        owner       : Identity,
        process     : UnsafeMutablePointer<Process>,
        construction: UnsafeMutablePointer<TaskConstruction>
    ) -> TaskControl? {
        for index in 0..<capacity where records[index] == nil {
            var generation = generations[index] &+ 1
            if generation == 0 { generation = 1 }
            generations[index] = generation

            records[index] = TaskRecord(
                owner       : owner,
                process     : process,
                construction: construction
            )
            return TaskControl(slot: UInt8(index), generation: generation)
        }

        return nil
    }

    /// The slot `control` names, while it still holds that generation's record.
    private static func index(of control: TaskControl) -> Int? {
        let index = Int(control.slot)
        guard index < capacity,
              generations[index] == control.generation,
              records[index] != nil
        else { return nil }

        return index
    }

    static func isLive(_ control: TaskControl) -> Bool {
        index(of: control) != nil
    }

    static func isOwned(
        _ control  : TaskControl,
        by identity: Identity
    ) -> Bool {
        guard let index = index(of: control) else { return false }
        return records[index]?.owner == identity
    }

    /// The process and construction of a task still being configured.
    static func configuring(
        _ control: TaskControl
    ) -> (process: UnsafeMutablePointer<Process>, construction: UnsafeMutablePointer<TaskConstruction>)? {
        guard let index = index(of: control),
              case .configuring(let construction)? = records[index]?.lifecycle,
              let process = records[index]?.process
        else { return nil }

        return (process, construction)
    }

    static func runningProcess(_ control: TaskControl) -> UnsafeMutablePointer<Process>? {
        guard let index = index(of: control),
              case .running? = records[index]?.lifecycle
        else { return nil }

        return records[index]?.process
    }

    /// The task in `index` when `identity` owns it, for a walk over every slot.
    static func control(
        at index        : Int,
        ownedBy identity: Identity
    ) -> TaskControl? {
        guard index < capacity, records[index]?.owner == identity else { return nil }
        return TaskControl(slot: UInt8(index), generation: generations[index])
    }

    static func retain(_ control: TaskControl) {
        guard let index = index(of: control),
              let references = records[index]?.capabilityReferences,
              references < UInt16.max
        else { return }

        records[index]?.capabilityReferences = references + 1
    }

    static func release(_ control: TaskControl) {
        guard let index = index(of: control),
              let references = records[index]?.capabilityReferences,
              references > 0
        else { return }

        records[index]?.capabilityReferences = references - 1
        collectIfUnused(index)
    }

    /// Leave `configuring` for `running`, handing back the construction the
    /// caller now has to release. `nil` is a task that was not configuring.
    static func markRunning(_ control: TaskControl) -> UnsafeMutablePointer<TaskConstruction>? {
        guard let index = index(of: control),
              case .configuring(let construction)? = records[index]?.lifecycle
        else { return nil }

        records[index]?.lifecycle = .running
        return construction
    }

    /// Record the exit, handing back the construction of a task killed before
    /// it ever started.
    static func markExited(
        _ control: TaskControl,
        code     : ExitCode
    ) -> UnsafeMutablePointer<TaskConstruction>? {
        settle(control, as: .exited(code))
    }

    /// Record the abort, handing back the construction it ends.
    static func markAborted(_ control: TaskControl) -> UnsafeMutablePointer<TaskConstruction>? {
        settle(control, as: .aborted)
    }

    static func markProcessGone(_ control: TaskControl) {
        guard let index = index(of: control) else { return }

        records[index]?.process = nil
        collectIfUnused(index)
    }

    static func status(_ control: TaskControl) -> (TaskState, ExitCode) {
        guard let index = index(of: control),
              let lifecycle = records[index]?.lifecycle
        else { return (.invalid, 0) }

        switch lifecycle {
            case .configuring: return (.configuring, 0)
            case .running: return (.running, 0)
            case .exited(let code): return (.exited, code)
            case .aborted: return (.aborted, 0)
        }
    }

    private static func settle(
        _ control: TaskControl,
        as final : TaskLifecycle
    ) -> UnsafeMutablePointer<TaskConstruction>? {
        guard let index = index(of: control) else { return nil }

        var construction: UnsafeMutablePointer<TaskConstruction>? = nil
        if case .configuring(let held)? = records[index]?.lifecycle {
            construction = held
        }

        records[index]?.lifecycle = final
        return construction
    }

    private static func collectIfUnused(_ index: Int) {
        guard records[index]?.capabilityReferences == 0,
              records[index]?.process == nil,
              let lifecycle = records[index]?.lifecycle
        else { return }

        switch lifecycle {
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
