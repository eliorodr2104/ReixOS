//
//  ProcessManager+Tasks.swift
//  ReixOS
//

import ReixABI

extension ProcessManager {

    /// Allocate an empty address space and publish only a stable task token.
    /// The returned process is unscheduled and cannot execute until `startTask`.
    mutating func createSuspendedTask(
        ownedBy owner: UnsafeMutablePointer<Process>
    ) -> (control: TaskControl, process: UnsafeMutablePointer<Process>)? {
        guard let process = try? spawnProcess() else { return nil }

        guard let control = TaskRegistry.create(
            owner  : owner.pointee.identity,
            process: process
        ) else {
            try? releaseAddressSpace(process)
            releaseProcess(process)
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
              let record = TaskRegistry.record(control),
              case .configuring = record.lifecycle,
              let process = record.process,
              let vma     = process.pointee.addressSpace.vmaManager
        else { return .invalidState }

        do {
            try vma.pointee.registerRegion(
                start      : range.start,
                size       : byteCount,
                permissions: [.read, .write, .user],
                backing    : .anonymous,
                flags      : .taskConstruction
            )
        } catch {
            return .invalidRange
        }

        var cursor = range.start
        while cursor < range.end {
            let page: PhysicalPage
            do {
                page = try ppm.pointee.alloc(Int(UserSpaceLayout.pageSize))
            } catch {
                try? vma.pointee.rollbackMapping(addr: range.start, size: byteCount)
                return .outOfMemory
            }

            let zero: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(page.address)
            zero.initialize(
                repeating: 0,
                count    : Int(UserSpaceLayout.pageSize)
            )

            do {
                try vmm.pointee.mapUserPage(
                    addressSpace: process.pointee.addressSpace,
                    virtual     : cursor,
                    physical    : page.address,
                    flags       : VMAPermissions([.read, .write, .user]).toPageFlags()
                )
            } catch {
                try? ppm.pointee.free(page)
                try? vma.pointee.rollbackMapping(addr: range.start, size: byteCount)
                return .outOfMemory
            }

            vma.pointee.noteMapped(1)
            cursor += UserSpaceLayout.pageSize
        }

        guard TaskRegistry.appendRegion(
            control,
            start: range.start,
            end  : range.end
        ) else {
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
              TaskRegistry.permitsWrite(
                control,
                start: range.start,
                end  : range.end
              ),
              let record  = TaskRegistry.record(control),
              let process = record.process
        else { return .invalidRange }

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
        permissions: TaskMemoryPermissions
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
              let record = TaskRegistry.record(control),
              case .configuring = record.lifecycle,
              let process = record.process,
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

        // The exact VMA was just accepted and task syscalls are serialized on
        // this single-core kernel, so this update cannot race or disagree.
        guard TaskRegistry.sealRegion(
            control,
            start      : range.start,
            end        : range.end,
            permissions: permissions
        ) else {
            TaskRegistry.markAborted(control)
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
              TaskRegistry.canSetContext(
                control,
                entry       : entry,
                stack       : stack,
                programBreak: programBreak
              ),
              let record   = TaskRegistry.record(control),
              let process  = record.process,
              let frame    = process.pointee.context,
              let metadata = process.pointee.metadata,
              let vma      = process.pointee.addressSpace.vmaManager,
              vma.pointee.commitTaskStack(top: stack)
        else { return .invalidRange }

        frame.pointee.elr   = entry
        frame.pointee.spel0 = stack
        frame.pointee.spsr  = 0

        metadata.pointee.programBreak = programBreak
        metadata.pointee.elfLoadBase  = entry
        metadata.pointee.elfLoadEnd   = programBreak
        vma.pointee.setInitialBreak(programBreak)

        return TaskRegistry.markContextSet(control) ? .ok : .invalidState
    }

    func startTask(
        _ control: TaskControl,
        context  : SyscallContext
    ) -> TaskStartResult {
        guard TaskRegistry.readyToStart(control),
              let record  = TaskRegistry.record(control),
              let process = record.process
        else { return TaskStartResult(result: .invalidState, pid: 0) }

        do {
            try context.scheduler.pointee.addTask(process)
        } catch {
            return TaskStartResult(result: .invalidState, pid: 0)
        }

        guard TaskRegistry.markRunning(control) else {
            context.scheduler.pointee.unlink(process, in: .ready)
            process.pointee.status = .new
            return TaskStartResult(result: .invalidState, pid: 0)
        }

        return TaskStartResult(result: .ok, pid: process.pointee.pid)
    }

    @discardableResult
    func abortTask(
        _ control: TaskControl,
        context  : SyscallContext
    ) -> TaskResult {
        guard let record = TaskRegistry.record(control),
              case .configuring = record.lifecycle,
              let process = record.process
        else { return .invalidState }

        TaskRegistry.markAborted(control)
        context.ipc.pointee.releaseCapabilities(of: process)
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
        guard let record = TaskRegistry.record(control),
              case .running = record.lifecycle,
              let process = record.process
        else { return .invalidState }

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

    /// A process owns the lifetime of every task it created. Losing the
    /// ProcessServer therefore cannot strand an unscheduled address space or
    /// leave its running jobs unsupervised.
    func terminateTasks(
        ownedBy identity: Identity,
        context         : SyscallContext
    ) {
        let controls = TaskRegistry.controls(ownedBy: identity)

        for index in 0..<controls.count {
            guard let control = controls[index],
                  let record = TaskRegistry.record(control)
            else { continue }

            switch record.lifecycle {
                case .configuring:
                    _ = abortTask(control, context: context)

                case .running:
                    guard let process = record.process else { continue }
                    _ = killProcess(process, reason: .killed, context: context)

                case .exited, .aborted:
                    break
            }
        }
    }
}
