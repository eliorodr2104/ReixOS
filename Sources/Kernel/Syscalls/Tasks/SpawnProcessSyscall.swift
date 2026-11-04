//
//  SpawnProcessSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 29/05/2026.
//

import ReixABI

public struct SpawnProcessSyscall: SyscallProvider {

    public static let number: SyscallNumber = .spawnProcess

    static let maximumGrantCount = 10

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {

        guard let currentProcess = Arch.CPU.getCurrentProcess(),
              let _ = currentProcess.pointee.metadata.pointee.capsTable.findFirst(for: .spawn) else {
            fail(frame)
            return
        }

        guard frame.pointee.x0 != 0 else {
            fail(frame)
            return // throw .nullPointer
        }

        guard frame.pointee.x1 <= 100 else {
            fail(frame)
            return
        }

        let length = Int(frame.pointee.x1)

        // Bounded storage for the complete environment of a bootstrap child.
        var grants      = InlineArray<10, CapGrant>(repeating: CapGrant())
        var grantsCount = 0

        guard frame.pointee.x3 <= UInt64(maximumGrantCount) else {
            fail(frame)
            return
        }

        if frame.pointee.x3 > 0 {
            let count = Int(frame.pointee.x3)

            let copied = withUnsafeMutableBytes(of: &grants) { raw in
                UserMemory.copyFromUser(
                    kernelDest: raw.baseAddress!,
                    userSrc   : frame.pointee.x2,
                    count     : count * MemoryLayout<CapGrant>.stride
                )
            }

            guard copied else {
                fail(frame)
                return
            }

            grantsCount = count
        }

        guard withUnsafePointer(to: &grants, {
            validateGrantPlan(
                UnsafeRawPointer($0).assumingMemoryBound(to: CapGrant.self),
                count: grantsCount,
                from : currentProcess
            )
        }) else {
            fail(frame)
            return
        }

        var childProcess: UnsafeMutablePointer<Process>?

        if length != 0 {
            withUnsafeTemporaryAllocation(
                byteCount: length + 1,
                alignment: MemoryLayout<CChar>.alignment
            ) { buffer in
                let base = buffer.baseAddress!

                guard UserMemory.copyFromUser(
                    kernelDest: base,
                    userSrc   : frame.pointee.x0,
                    count     : length
                ) else { fail(frame); return }

                base.storeBytes(of: 0, toByteOffset: length, as: CChar.self)
                let cPath = base.assumingMemoryBound(to: CChar.self)

                childProcess = try? context.processManager.pointee.spawnProcess(path: cPath)
            }

        }

        guard let childProcess,
              let committed = withUnsafePointer(to: &grants, {
                  commit(
                      childProcess,
                      parent : currentProcess,
                      grants : UnsafeRawPointer($0).assumingMemoryBound(to: CapGrant.self),
                      count  : grantsCount,
                      context: context
                  )
              })
        else {
            fail(frame)
            return
        }

        frame.pointee.x0 = committed.pid
        frame.pointee.x1 = UInt64(committed.endpoint)
    }


    /// Checks the whole environment before the kernel allocates a child.
    ///
    /// The child starts empty, so unique in-range slots plus grantable sources
    /// make every later injection deterministic. Rights wider than the kernel
    /// representation are refused.
    static func validateGrantPlan(
        _ grants     : UnsafePointer<CapGrant>,
          count      : Int,
          from parent: UnsafeMutablePointer<Process>
    ) -> Bool {
        guard count >= 0, count <= maximumGrantCount,
              let metadata = parent.pointee.metadata
        else { return false }

        for index in 0..<count {
            let grant = grants[index]

            guard grant.targetSlot < CapsTable.slotCount,
                  grant.rights <= UInt32(UInt16.max),
                  let source = metadata.pointee.capsTable.resolve(grant.sourceHandle),
                  source.rights.contains(.grant)
            else { return false }

            for earlier in 0..<index where grants[earlier].targetSlot == grant.targetSlot {
                return false
            }
        }

        return true
    }


    /// Commits a fully built but suspended child.
    ///
    /// No path returns a PID unless every capability, the bootstrap endpoint,
    /// the family link and the scheduler insertion succeeded. Any refusal gives
    /// back the child's address space, capability references and process record.
    static func commit(
        _ child  : UnsafeMutablePointer<Process>,
          parent : UnsafeMutablePointer<Process>,
          grants : UnsafePointer<CapGrant>,
          count  : Int,
          context: SyscallContext
    ) -> (pid: PID, endpoint: UInt32)? {
        guard validateGrantPlan(grants, count: count, from: parent) else {
            discard(child, parentEndpoint: nil, parent: parent, context: context)
            return nil
        }

        for index in 0..<count {
            let grant = grants[index]

            guard context.ipc.pointee.injectCapability(
                from  : parent,
                handle: grant.sourceHandle,
                to    : child,
                slot  : grant.targetSlot,
                rights: CapRights(rawValue: UInt16(grant.rights))
            ) else {
                discard(child, parentEndpoint: nil, parent: parent, context: context)
                return nil
            }
        }

        guard case .success(let parentEndpoint) = context.ipc.pointee.spawnEndpoint(
            for: parent,
            and: child
        ) else {
            discard(child, parentEndpoint: nil, parent: parent, context: context)
            return nil
        }

        child.pointee.family.parent = parent
        parent.pointee.family.pushChild(child)

        do {
            try context.scheduler.pointee.addTask(child)
        } catch {
            discard(
                child,
                parentEndpoint: parentEndpoint,
                parent: parent,
                context: context
            )
            return nil
        }

        return (child.pointee.pid, parentEndpoint)
    }


    private static func discard(
        _ child         : UnsafeMutablePointer<Process>,
          parentEndpoint: UInt32?,
          parent        : UnsafeMutablePointer<Process>,
          context       : SyscallContext
    ) {
        if let parentEndpoint {
            _ = context.ipc.pointee.releaseCapability(parentEndpoint, of: parent)
        }

        context.ipc.pointee.releaseCapabilities(of: child)
        try? context.processManager.pointee.releaseAddressSpace(child)
        context.processManager.pointee.releaseProcess(child)
    }


    @inline(__always)
    private static func fail(_ frame: UnsafeMutablePointer<Arch.TrapFrame>) {
        frame.pointee.x0 = UInt64.max
        frame.pointee.x1 = UInt64(UInt32.max)
    }
}
