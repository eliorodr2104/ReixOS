//
//  ProcessManager+Tasks.swift
//  ReixOS
//

import ReixABI

extension ProcessManager {

    /// Allocate an empty address space and publish only a stable task token.
    /// The returned process is unscheduled and cannot execute until `startTask`.
    ///
    /// The construction object is taken first because it is the cheapest
    /// thing to give back: every refusal below leaves no slot and no charge.
    ///
    /// - Parameter frameLimit: the ceiling the owner asks for the child, clamped
    ///   to the owner's own. `nil` inherits it whole.
    mutating func createSuspendedTask(
        ownedBy owner: UnsafeMutablePointer<Process>,
        name         : InlineArray<16, UInt8>? = nil,
        nameLength   : Int = 0,
        frameLimit   : UInt32? = nil
    ) -> (control: TaskControl, process: UnsafeMutablePointer<Process>)? {
        guard let budget       = owner.pointee.metadata?.pointee.budget,
              let construction = makeConstruction(chargedTo: budget)
        else { return nil }

        guard let process = try? spawnProcess(
            name      : name,
            nameLength: nameLength,
            frameLimit: frameLimit
        ) else {
            releaseConstruction(construction)
            return nil
        }

        guard let control = TaskRegistry.create(
            owner       : owner.pointee.identity,
            process     : process,
            construction: construction
        ) else {
            try? releaseAddressSpace(process)
            releaseProcess(process)
            releaseConstruction(construction)
            return nil
        }

        process.pointee.metadata.pointee.taskControl = control
        return (control, process)
    }

    func mapTaskAnonymous(
        _ control : TaskControl,
        at address: VirtualAddress,
        pages     : UInt32
    ) -> TaskResult {
        guard pages > 0, pages <= TaskABI.maximumPagesPerMapping else {
            return .invalidRange
        }

        let byteCount = UInt64(pages) * UserSpaceLayout.pageSize
        guard address & (UserSpaceLayout.pageSize - 1) == 0,
              let range = UserSpaceLayout.checkedUserRange(
                address: address,
                size   : byteCount
              ),
              let process = TaskRegistry.configuring(control)?.process,
              let vma     = process.pointee.addressSpace.vmaManager
        else { return .invalidState }

        do {
            try vma.pointee.registerRegion(
                start      : range.start,
                size       : byteCount,
                permissions: [.read, .write, .user],
                backing    : .anonymous,
                flags      : .taskConstruction,
                memoryType : .normal
            )
        } catch {
            if case .regionLimitReached = error { return .full }
            return .invalidRange
        }

        let fill = TaskMapFill(
            ppm   : ppm,
            vmm   : vmm,
            vma   : vma,
            root  : process.pointee.addressSpace.rootTablePhysical,
            budget: vma.pointee.budget,
            start : range.start,
            end   : range.end
        )

        do {
            _ = try Preemption.run(TaskMapAnonymous.self, fill)
        } catch {
            try? vma.pointee.rollbackMapping(addr: range.start, size: byteCount)
            return .outOfMemory
        }

        // Looked up again because the fill above may have been preempted.
        guard let construction = TaskRegistry.configuring(control)?.construction,
              construction.pointee.append(start: range.start, end: range.end)
        else {
            try? vma.pointee.rollbackMapping(addr: range.start, size: byteCount)
            return .full
        }

        return .ok
    }

    func writeTask(
        _ control  : TaskControl,
        at address : VirtualAddress,
        from source: VirtualAddress,
        count      : UInt64
    ) -> TaskResult {
        guard count > 0,
              count <= TaskABI.maximumWriteBytes,
              count <= UInt64(Int.max),
              let range = UserSpaceLayout.checkedUserRange(
                address: address,
                size   : count
              ),
              UserMemory.validateRegion(
                addr       : source,
                size       : Int(count),
                permissions: [.read, .user]
              ),
              let task = TaskRegistry.configuring(control),
              task.construction.pointee.permitsWrite(
                start: range.start,
                end  : range.end
              )
        else { return .invalidRange }

        let process = task.process

        var target       = range.start
        var sourceOffset : UInt64 = 0

        while target < range.end {
            let pageBase   = target & ~(UserSpaceLayout.pageSize - 1)
            let pageOffset = target - pageBase
            let remaining  = range.end - target
            let inPage     = UserSpaceLayout.pageSize - pageOffset
            let chunk      = remaining < inPage ? remaining : inPage

            guard let physical = vmm.pointee.physicalAddressOf(
                rootTable: process.pointee.addressSpace.rootTablePhysical,
                virtual  : pageBase
            ) else { return .invalidState }

            let destination: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(
                physical + pageOffset
            )
            let sourcePointer = UnsafeRawPointer(
                bitPattern: UInt(source + sourceOffset)
            )!

            UnsafeMutableRawPointer(destination).copyMemory(
                from     : sourcePointer,
                byteCount: Int(chunk)
            )

            target       += chunk
            sourceOffset += chunk
        }

        return .ok
    }

    func sealTaskRegion(
        _ control  : TaskControl,
        at address : VirtualAddress,
        pages      : UInt32,
        permissions: TaskMemoryPermissions,
        context    : SyscallContext
    ) -> TaskResult {
        guard pages > 0, pages <= TaskABI.maximumPagesPerMapping,
              permissions.contains(.read),
              permissions.rawValue & ~TaskMemoryPermissions.known.rawValue == 0,
              !permissions.contains([.write, .execute])
        else { return .permissionConflict }

        let size = UInt64(pages) * UserSpaceLayout.pageSize
        guard address & (UserSpaceLayout.pageSize - 1) == 0,
              let range = UserSpaceLayout.checkedUserRange(
                address: address,
                size   : size
              ),
              let process = TaskRegistry.configuring(control)?.process,
              let vma     = process.pointee.addressSpace.vmaManager
        else { return .invalidState }

        var final: VMAPermissions = [.read, .user]
        if permissions.contains(.write)   { final.insert(.write) }
        if permissions.contains(.execute) { final.insert(.execute) }

        guard vma.pointee.protectTaskRegion(
            start      : range.start,
            end        : range.end,
            permissions: final
        ) else { return .invalidRange }

        // The VMA and the construction should agree, but a disagreement is
        // torn down like `abortTask` so the child never outlives its record.
        guard let construction = TaskRegistry.configuring(control)?.construction,
              construction.pointee.seal(
                start      : range.start,
                end        : range.end,
                permissions: permissions
              )
        else {
            abortTask(control, context: context)
            return .invalidState
        }

        return .ok
    }

    func setTaskContext(
        _ control   : TaskControl,
        entry       : VirtualAddress,
        stack       : VirtualAddress,
        programBreak: VirtualAddress
    ) -> TaskResult {
        guard stack & 0xF == 0,
              let task = TaskRegistry.configuring(control),
              task.construction.pointee.canSetContext(
                entry       : entry,
                stack       : stack,
                programBreak: programBreak
              ),
              let frame    = task.process.pointee.context,
              let metadata = task.process.pointee.metadata,
              let vma      = task.process.pointee.addressSpace.vmaManager,
              vma.pointee.commitTaskStack(top: stack)
        else { return .invalidRange }

        frame.pointee.elr   = entry
        frame.pointee.spel0 = stack
        frame.pointee.spsr  = 0

        metadata.pointee.programBreak = programBreak
        metadata.pointee.elfLoadBase  = entry
        metadata.pointee.elfLoadEnd   = programBreak
        vma.pointee.setInitialBreak(programBreak)

        task.construction.pointee.contextSet = true
        return .ok
    }

    func startTask(
        _ control: TaskControl,
        context  : SyscallContext
    ) -> TaskStartResult {
        guard let task = TaskRegistry.configuring(control),
              task.construction.pointee.isReady
        else { return TaskStartResult(result: .invalidState, pid: 0) }

        let process = task.process

        do {
            try context.scheduler.pointee.addTask(process)
        } catch {
            return TaskStartResult(result: .invalidState, pid: 0)
        }

        guard let construction = TaskRegistry.markRunning(control) else {
            context.scheduler.pointee.unlink(process, in: .ready)
            process.pointee.status = .new
            return TaskStartResult(result: .invalidState, pid: 0)
        }

        releaseConstruction(construction)
        return TaskStartResult(result: .ok, pid: process.pointee.pid)
    }

    @discardableResult
    func abortTask(
        _ control: TaskControl,
        context  : SyscallContext
    ) -> TaskResult {
        guard let process = TaskRegistry.configuring(control)?.process else {
            return .invalidState
        }

        releaseConstruction(TaskRegistry.markAborted(control))
        releaseCapabilitiesInSteps(of: process, context)
        try? releaseAddressSpace(process)
        releaseProcess(process)
        return .ok
    }

    @discardableResult
    func terminateTask(
        _ control: TaskControl,
        frame    : UnsafeMutablePointer<Arch.TrapFrame>,
        context  : SyscallContext
    ) -> TaskResult {
        guard let process = TaskRegistry.runningProcess(control) else {
            return .invalidState
        }

        if process == Arch.CPU.getCurrentProcess() {
            killCurrent(frame: frame, reason: .killed, context: context)
            return .ok
        }

        _ = killProcess(process, reason: .killed, context: context)
        return .ok
    }

    func taskStatus(_ control: TaskControl) -> TaskStatus {
        let status = TaskRegistry.status(control)
        return TaskStatus(state: status.0, exitCode: status.1)
    }

    /// Give back a construction object and its frame. `nil` is a task that
    /// left `configuring` before, so it had nothing left to give.
    func releaseConstruction(_ construction: UnsafeMutablePointer<TaskConstruction>?) {
        guard let construction else { return }

        if let budget = construction.pointee.budget {
            refundFrames(budget, 1)
            releaseBudget(budget, heap: heap)
        }

        heap.pointee.kfree(construction)
    }


    /// A construction object charged one frame to `budget`, or nothing, with
    /// the charge given back when the heap refuses.
    private func makeConstruction(
        chargedTo budget: UnsafeMutablePointer<FrameBudget>
    ) -> UnsafeMutablePointer<TaskConstruction>? {
        guard chargeFrames(budget, 1) else { return nil }

        guard let cell = heap.pointee.kmallocOrNil(TaskConstruction.self) else {
            refundFrames(budget, 1)
            return nil
        }

        // Zero is the empty construction, see `TaskConstruction`, so nothing
        // of its size is built on the stack and copied in.
        let zeroed = UnsafeMutableRawPointer(cell).initializeMemory(
            as       : UInt8.self,
            repeating: 0,
            count    : MemoryLayout<TaskConstruction>.size
        )
        let construction = UnsafeMutableRawPointer(zeroed).bindMemory(
            to      : TaskConstruction.self,
            capacity: 1
        )
        construction.pointee.budget = budget
        rxRetain(budget)
        return construction
    }
}
