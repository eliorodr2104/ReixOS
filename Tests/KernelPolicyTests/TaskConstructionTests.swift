//
//  TaskConstructionTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport
import KernelHostShims

extension KernelPolicyTestRoot {
@Suite("Suspended task construction", .serialized)
struct TaskConstructionTests {

    @Test("the image is sealed before start and the task cap becomes a stable job")
    func sealedStartAndStableJob() {
        withProcessManager(pages: 256) { ram, heap, manager in
            TaskRegistry.resetForTesting()
            defer {
                UserMemory.validationOverride = nil
                TaskRegistry.resetForTesting()
            }

            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            defer { UnsafeMutableRawPointer(scheduler).deallocate() }

            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            guard let parent = try? manager.pointee.spawnProcess() else {
                Issue.record("could not create task owner")
                return
            }

            _ = parent.pointee.metadata.pointee.capsTable.install(
                Capability(target: .power, badge: 0, rights: [.spawn])
            )

            let parentName = Array("ProcessServer.elf".utf8)
            parentName.withUnsafeBufferPointer {
                parent.pointee.metadata.pointee.setName(
                    from : $0.baseAddress!,
                    count: $0.count
                )
            }

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: parent)))
            defer { Arch.CPU.setCurrentProcess(0) }

            let context = SyscallContext(
                processManager: manager,
                scheduler     : scheduler,
                ipc           : ipc,
                ppm           : ram.ppm
            )

            let childName = Array("Shell.elf".utf8)
            TraceRing.reset()
            var create = Arch.TrapFrame()
            childName.withUnsafeBufferPointer { bytes in
                UserMemory.validationOverride = { address, size, permissions in
                    address == UInt64(UInt(bitPattern: bytes.baseAddress!)) &&
                    size == bytes.count && permissions == [.read, .user]
                }
                create.x0 = UInt64(UInt(bitPattern: bytes.baseAddress!))
                create.x1 = UInt64(bytes.count)
                TaskCreateSyscall.handle(frame: &create, context: context)
            }
            UserMemory.validationOverride = nil

            let taskHandle = UInt32(truncatingIfNeeded: create.x0)
            #expect(taskHandle != UInt32.max)
            #expect(UInt32(truncatingIfNeeded: create.x1) != UInt32.max)

            guard let taskCapability = parent.pointee.metadata.pointee.capsTable.resolve(taskHandle),
                  case .task(let control) = taskCapability.target,
                  let child = TaskRegistry.record(control)?.process
            else {
                Issue.record("taskCreate did not publish a task capability")
                return
            }

            #expect(child.pointee.metadata.pointee.nameLength == UInt8(childName.count))
            for index in 0..<childName.count {
                #expect(child.pointee.metadata.pointee.name[index] == childName[index])
            }
            for index in childName.count..<TaskCreation.maximumNameBytes {
                #expect(child.pointee.metadata.pointee.name[index] == 0)
            }
            #expect(child.pointee.metadata.pointee.capsTable.resolve(BootCap.profiler.rawValue) == nil)

            var tracedName: TraceEvent?
            TraceRing.forEachEvent { event in
                if event.code == TraceCode.procName,
                   event.pid == UInt32(truncatingIfNeeded: child.pointee.pid) {
                    tracedName = event
                }
            }
            #expect(tracedName?.info == UInt16(childName.count))
            for index in 0..<TaskCreation.maximumNameBytes {
                let word  = index < 8 ? tracedName?.a : tracedName?.b
                let shift = UInt64(8 * (index & 7))
                let byte  = UInt8(truncatingIfNeeded: (word ?? UInt64.max) >> shift)
                let expected = index < childName.count ? childName[index] : 0
                #expect(byte == expected)
            }

            let text  = UserSpaceLayout.elfBaseTypical
            let stack = UserSpaceLayout.stackTop - UserSpaceLayout.pageSize

            var mapText = Arch.TrapFrame()
            mapText.x0 = UInt64(taskHandle)
            mapText.x1 = text
            mapText.x2 = 1
            TaskMapAnonymousSyscall.handle(frame: &mapText, context: context)
            #expect(mapText.x0 == TaskResult.ok.rawValue)

            var mapStack = Arch.TrapFrame()
            mapStack.x0 = UInt64(taskHandle)
            mapStack.x1 = stack
            mapStack.x2 = 1
            TaskMapAnonymousSyscall.handle(frame: &mapStack, context: context)
            #expect(mapStack.x0 == TaskResult.ok.rawValue)

            let image: [UInt8] = [0x00, 0x00, 0x20, 0xD4]
            image.withUnsafeBytes { bytes in
                UserMemory.validationOverride = { address, size, permissions in
                    address == UInt64(UInt(bitPattern: bytes.baseAddress!)) &&
                    size == bytes.count && permissions == [.read, .user]
                }

                var write = Arch.TrapFrame()
                write.x0 = UInt64(taskHandle)
                write.x1 = text
                write.x2 = UInt64(UInt(bitPattern: bytes.baseAddress!))
                write.x3 = UInt64(bytes.count)
                TaskWriteSyscall.handle(frame: &write, context: context)
                #expect(write.x0 == TaskResult.ok.rawValue)
            }

            var wx = Arch.TrapFrame()
            wx.x0 = UInt64(taskHandle)
            wx.x1 = text
            wx.x2 = 1
            wx.x3 = UInt64(TaskMemoryPermissions([.read, .write, .execute]).rawValue)
            TaskSealAndProtectSyscall.handle(frame: &wx, context: context)
            #expect(wx.x0 == TaskResult.permissionConflict.rawValue)

            var sealText = Arch.TrapFrame()
            reset_instruction_cache_sync_record()
            sealText.x0 = UInt64(taskHandle)
            sealText.x1 = text
            sealText.x2 = 1
            sealText.x3 = UInt64(TaskMemoryPermissions([.read, .execute]).rawValue)
            TaskSealAndProtectSyscall.handle(frame: &sealText, context: context)
            #expect(sealText.x0 == TaskResult.ok.rawValue)
            #expect(instruction_cache_sync_calls() == 1)
            #expect(instruction_cache_synced_size() == UserSpaceLayout.pageSize)
            #expect(instruction_cache_synced_base() == ram.vmm.pointee.physicalAddressOf(
                rootTable: child.pointee.addressSpace.rootTablePhysical, virtual: text
            ))

            var sealStack = Arch.TrapFrame()
            sealStack.x0 = UInt64(taskHandle)
            sealStack.x1 = stack
            sealStack.x2 = 1
            sealStack.x3 = UInt64(TaskMemoryPermissions([.read, .write]).rawValue)
            TaskSealAndProtectSyscall.handle(frame: &sealStack, context: context)
            #expect(sealStack.x0 == TaskResult.ok.rawValue)
            #expect(instruction_cache_sync_calls() == 1)

            var setContext = Arch.TrapFrame()
            setContext.x0 = UInt64(taskHandle)
            setContext.x1 = text
            setContext.x2 = UserSpaceLayout.stackTop
            setContext.x3 = text + UserSpaceLayout.pageSize
            TaskSetContextSyscall.handle(frame: &setContext, context: context)
            #expect(setContext.x0 == TaskResult.ok.rawValue)

            let committedStack = child.pointee.addressSpace.vmaManager?.pointee.vmaList.search(
                at: stack
            )
            #expect(committedStack?.pointee.mappingFlags.contains(.growDown) == true)
            #expect(committedStack?.pointee.mappingFlags.contains(.taskConstruction) == false)

            var start = Arch.TrapFrame()
            start.x0 = UInt64(taskHandle)
            TaskStartSyscall.handle(frame: &start, context: context)
            #expect(start.x0 == TaskResult.ok.rawValue)
            #expect(start.x1 == child.pointee.pid)
            #expect(scheduler.pointee.search(in: .ready, to: child.pointee.pid) == child)

            guard let jobCapability = parent.pointee.metadata.pointee.capsTable.resolve(taskHandle) else {
                Issue.record("task handle disappeared at start")
                return
            }
            #expect(jobCapability.target == .job(control))
            #expect(!jobCapability.rights.contains(.taskConfigure))
            #expect(!jobCapability.rights.contains(.taskStart))

            var lateWrite = Arch.TrapFrame()
            lateWrite.x0 = UInt64(taskHandle)
            lateWrite.x1 = text
            lateWrite.x2 = 1
            lateWrite.x3 = 1
            TaskWriteSyscall.handle(frame: &lateWrite, context: context)
            #expect(lateWrite.x0 == TaskResult.invalidCapability.rawValue)

            var cancel = Arch.TrapFrame()
            cancel.x0 = UInt64(taskHandle)
            TaskTerminateSyscall.handle(frame: &cancel, context: context)
            #expect(cancel.x0 == TaskResult.ok.rawValue)

            let reaped = scheduler.pointee.reapChild(child)
            #expect(reaped)
            manager.pointee.releaseProcess(child)

            var status = Arch.TrapFrame()
            status.x0 = UInt64(taskHandle)
            TaskStatusSyscall.handle(frame: &status, context: context)
            #expect(status.x0 == TaskState.exited.rawValue)
            #expect(status.x1 == 0)

            #expect(context.ipc.pointee.releaseCapability(taskHandle, of: parent).isSuccess)
            #expect(TaskRegistry.record(control) == nil)
        }
    }


    @Test("malformed task identity is refused before allocation and unnamed creation still inherits")
    func taskIdentityValidationAndCompatibility() {
        withProcessManager(pages: 160) { ram, heap, manager in
            TaskRegistry.resetForTesting()
            defer {
                UserMemory.validationOverride = nil
                TaskRegistry.resetForTesting()
            }

            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            defer { UnsafeMutableRawPointer(scheduler).deallocate() }

            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            guard let parent = try? manager.pointee.spawnProcess() else {
                Issue.record("could not create task owner")
                return
            }

            _ = parent.pointee.metadata.pointee.capsTable.install(
                Capability(target: .power, badge: 0, rights: [.spawn])
            )
            let parentName = Array("ProcessServer.elf".utf8)
            parentName.withUnsafeBufferPointer {
                parent.pointee.metadata.pointee.setName(
                    from : $0.baseAddress!,
                    count: $0.count
                )
            }

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: parent)))
            defer { Arch.CPU.setCurrentProcess(0) }

            let context = SyscallContext(
                processManager: manager,
                scheduler     : scheduler,
                ipc           : ipc,
                ppm           : ram.ppm
            )
            let pagesBefore = ram.ppm.pointee.allocatedPages
            let capsBefore = (0..<Int(CapsTable.slotCount)).map {
                parent.pointee.metadata.pointee.capsTable.resolve(UInt32($0))
            }

            var nullName = Arch.TrapFrame()
            nullName.x1 = 1
            TaskCreateSyscall.handle(frame: &nullName, context: context)
            #expect(UInt32(truncatingIfNeeded: nullName.x0) == UInt32.max)

            var emptyName = Arch.TrapFrame()
            emptyName.x0 = 1
            TaskCreateSyscall.handle(frame: &emptyName, context: context)
            #expect(UInt32(truncatingIfNeeded: emptyName.x0) == UInt32.max)

            var oversized = Arch.TrapFrame()
            oversized.x0 = 1
            oversized.x1 = UInt64(TaskCreation.maximumNameBytes + 1)
            TaskCreateSyscall.handle(frame: &oversized, context: context)
            #expect(UInt32(truncatingIfNeeded: oversized.x0) == UInt32.max)

            var unrepresentable = Arch.TrapFrame()
            unrepresentable.x0 = 1
            unrepresentable.x1 = UInt64.max
            TaskCreateSyscall.handle(frame: &unrepresentable, context: context)
            #expect(UInt32(truncatingIfNeeded: unrepresentable.x0) == UInt32.max)

            let unreadable = Array("Shell.elf".utf8)
            unreadable.withUnsafeBufferPointer { bytes in
                UserMemory.validationOverride = { _, _, _ in false }
                var request = Arch.TrapFrame()
                request.x0 = UInt64(UInt(bitPattern: bytes.baseAddress!))
                request.x1 = UInt64(bytes.count)
                TaskCreateSyscall.handle(frame: &request, context: context)
                #expect(UInt32(truncatingIfNeeded: request.x0) == UInt32.max)
            }
            UserMemory.validationOverride = nil

            for rejectedName: [UInt8] in [[0], [0x1B], [0x0A], [0x7F]] {
                rejectedName.withUnsafeBufferPointer { bytes in
                    UserMemory.validationOverride = { address, size, permissions in
                        address == UInt64(UInt(bitPattern: bytes.baseAddress!)) &&
                        size == bytes.count && permissions == [.read, .user]
                    }
                    var request = Arch.TrapFrame()
                    request.x0 = UInt64(UInt(bitPattern: bytes.baseAddress!))
                    request.x1 = UInt64(bytes.count)
                    TaskCreateSyscall.handle(frame: &request, context: context)
                    #expect(UInt32(truncatingIfNeeded: request.x0) == UInt32.max)
                }
            }
            UserMemory.validationOverride = nil

            #expect(ram.ppm.pointee.allocatedPages == pagesBefore)
            let controls = TaskRegistry.controls(ownedBy: parent.pointee.identity)
            for index in 0..<controls.count { #expect(controls[index] == nil) }
            for index in 0..<Int(CapsTable.slotCount) {
                #expect(
                    parent.pointee.metadata.pointee.capsTable.resolve(UInt32(index)) ==
                    capsBefore[index]
                )
            }

            let exactName = Array("ProfileAuthority".utf8)
            #expect(exactName.count == TaskCreation.maximumNameBytes)
            var named = Arch.TrapFrame()
            exactName.withUnsafeBufferPointer { bytes in
                UserMemory.validationOverride = { address, size, permissions in
                    address == UInt64(UInt(bitPattern: bytes.baseAddress!)) &&
                    size == bytes.count && permissions == [.read, .user]
                }
                named.x0 = UInt64(UInt(bitPattern: bytes.baseAddress!))
                named.x1 = UInt64(bytes.count)
                TaskCreateSyscall.handle(frame: &named, context: context)
            }
            UserMemory.validationOverride = nil

            let namedTask = UInt32(truncatingIfNeeded: named.x0)
            let namedBootstrap = UInt32(truncatingIfNeeded: named.x1)
            guard namedTask != UInt32.max,
                  let namedCapability = parent.pointee.metadata.pointee.capsTable.resolve(namedTask),
                  case .task(let namedControl) = namedCapability.target,
                  let namedChild = TaskRegistry.record(namedControl)?.process
            else {
                Issue.record("exact-width task identity was refused")
                return
            }

            #expect(namedChild.pointee.metadata.pointee.nameLength == UInt8(exactName.count))
            for index in 0..<exactName.count {
                #expect(namedChild.pointee.metadata.pointee.name[index] == exactName[index])
            }
            #expect(namedChild.pointee.metadata.pointee.capsTable.resolve(BootCap.profiler.rawValue) == nil)

            var abortNamed = Arch.TrapFrame()
            abortNamed.x0 = UInt64(namedTask)
            TaskAbortSyscall.handle(frame: &abortNamed, context: context)
            #expect(abortNamed.x0 == TaskResult.ok.rawValue)
            #expect(context.ipc.pointee.releaseCapability(namedTask, of: parent).isSuccess)
            #expect(context.ipc.pointee.releaseCapability(namedBootstrap, of: parent).isSuccess)

            var legacy = Arch.TrapFrame()
            TaskCreateSyscall.handle(frame: &legacy, context: context)
            let taskHandle = UInt32(truncatingIfNeeded: legacy.x0)
            guard taskHandle != UInt32.max,
                  let capability = parent.pointee.metadata.pointee.capsTable.resolve(taskHandle),
                  case .task(let control) = capability.target,
                  let child = TaskRegistry.record(control)?.process
            else {
                Issue.record("unnamed taskCreate compatibility path failed")
                return
            }

            let inheritedLength = min(parentName.count, TaskCreation.maximumNameBytes)
            #expect(child.pointee.metadata.pointee.nameLength == UInt8(inheritedLength))
            for index in 0..<inheritedLength {
                #expect(child.pointee.metadata.pointee.name[index] == parentName[index])
            }

            var abort = Arch.TrapFrame()
            abort.x0 = UInt64(taskHandle)
            TaskAbortSyscall.handle(frame: &abort, context: context)
            #expect(abort.x0 == TaskResult.ok.rawValue)
            #expect(context.ipc.pointee.releaseCapability(taskHandle, of: parent).isSuccess)
            #expect(context.ipc.pointee.releaseCapability(UInt32(truncatingIfNeeded: legacy.x1), of: parent).isSuccess)
        }
    }

    @Test("task tokens reject stale generations and non-owner configuration")
    func stableGenerationAndOwner() {
        withProcessManager(pages: 160) { ram, heap, manager in
            TaskRegistry.resetForTesting()
            defer { TaskRegistry.resetForTesting() }

            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            defer { UnsafeMutableRawPointer(scheduler).deallocate() }

            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            guard let owner = try? manager.pointee.spawnProcess(),
                  let intruder = try? manager.pointee.spawnProcess(),
                  let first    = manager.pointee.createSuspendedTask(ownedBy: owner)
            else {
                Issue.record("could not create owner, intruder, and task")
                return
            }

            let context = SyscallContext(
                processManager: manager,
                scheduler     : scheduler,
                ipc           : ipc,
                ppm           : ram.ppm
            )

            let copied = Capability(
                target: .task(first.control),
                badge : 0,
                rights: [.taskConfigure]
            )
            let copiedHandle = intruder.pointee.metadata.pointee.capsTable.install(copied)!
            ipc.pointee.retain(copied)

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: intruder)))
            var map = Arch.TrapFrame()
            map.x0 = UInt64(copiedHandle)
            map.x1 = UserSpaceLayout.elfBaseTypical
            map.x2 = 1
            TaskMapAnonymousSyscall.handle(frame: &map, context: context)
            #expect(map.x0 == TaskResult.invalidCapability.rawValue)

            #expect(ipc.pointee.releaseCapability(copiedHandle, of: intruder).isSuccess)
            #expect(manager.pointee.abortTask(first.control, context: context) == .ok)
            #expect(TaskRegistry.record(first.control) == nil)

            guard let second = manager.pointee.createSuspendedTask(ownedBy: owner) else {
                Issue.record("registry did not reuse an available slot")
                return
            }

            #expect(second.control.slot == first.control.slot)
            #expect(second.control.generation != first.control.generation)
            #expect(TaskRegistry.status(first.control).0 == .invalid)

            _ = manager.pointee.abortTask(second.control, context: context)
            Arch.CPU.setCurrentProcess(0)
        }
    }
}
}

private extension Result where Success == Void, Failure == IPCError {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
