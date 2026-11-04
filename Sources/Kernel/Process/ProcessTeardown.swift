//
//  ProcessTeardown.swift
//  ReixOS
//

import ReixABI

/// A death, including its owned tasks, under one teardown driver.
///
/// `beginDeath` removes live queue membership and publishes `terminated` before
/// the first step. That state refuses wakes and lookups; it does not prove
/// membership in the zombie queue. Only the last stage publishes a reapable
/// corpse. A parent parked in `reapChild` stays parked until the hand-off.
///
/// The outgoing reply list, task registry, children and incoming reply list are
/// visited one item per step. Owned tasks descend into this same operation,
/// never another `killProcess` or `Preemption.run`: a nested driver opens no
/// windows and would make an entire child death one masked step.
///
/// Pending owners lend their unused scheduler `next` link to the continuation
/// chain. They are terminated and off every queue, and only interrupt handlers
/// run in windows, so nobody else can write those links. Popping clears the
/// link before the owner can become a zombie. Depth costs no kernel stack and
/// no allocation, even when a task owns tasks itself.
///
/// Children are collected only when the zombie queue really owns them. The
/// rest go to the old parent, else live init, else nobody, preserving their
/// sibling order. Reparenting also takes one child per step.
///
/// The remaining stages keep the address-space, waits, capability and corpse
/// order. A refused address-space free ends that stage, not the death.
struct ProcessTeardown: ResumableOperation {

    typealias Failure = Never

    private enum Stage {
        case outgoingReply
        case tasks
        case children
        case replies
        case addressSpace
        case waits
        case capabilities
        case unlink
        case metadata
        case release
    }

    private let context: SyscallContext

    private var process: UnsafeMutablePointer<Process>
    private var parent : UnsafeMutablePointer<Process>?
    private var pending: UnsafeMutablePointer<Process>? = nil
    private var server : UnsafeMutablePointer<Process>?
    private var waiter : UnsafeMutablePointer<Process>?
    private var previousWaiter: UnsafeMutablePointer<Process>? = nil
    private var adoptedTail   : UnsafeMutablePointer<Process>? = nil
    private var taskSlot      : Int = 0
    private var aborting      : Bool = false

    private var stage       : Stage = .outgoingReply
    private var addressSpace: AddressSpaceRelease? = nil
    private var capabilities: CapabilityRelease? = nil


    /// `parent` is the stable reapChild destination captured before the run.
    /// `server` preserves the outgoing link that the terminated status erased.
    init(
        process: UnsafeMutablePointer<Process>,
        parent : UnsafeMutablePointer<Process>?,
        server : UnsafeMutablePointer<Process>? = nil,
        context: SyscallContext
    ) {
        self.process = process
        self.parent  = parent
        self.server  = server
        self.waiter  = server?.pointee.replyTo
        self.context = context
    }


    mutating func step() -> Progress {
        switch stage {
            case .outgoingReply:
                if let server, let waiter {
                    if waiter == process {
                        RendezvousIPC.unlinkWaiter(process, from: server, after: previousWaiter)
                        self.waiter = nil
                        self.server = nil
                    } else {
                        previousWaiter = waiter
                        self.waiter   = waiter.pointee.nextWaiter
                    }
                    return .more
                }

                stage = .tasks
                return .more

            case .tasks:
                guard !aborting, taskSlot < TaskRegistry.capacity else {
                    stage = .children
                    return .more
                }

                let slot = taskSlot
                taskSlot += 1

                guard let control = TaskRegistry.control(at: slot, ownedBy: process.pointee.identity)
                else { return .more }

                let child: UnsafeMutablePointer<Process>
                let abort: Bool

                if let running = TaskRegistry.runningProcess(control) {
                    child = running
                    abort = false
                } else if let configuring = TaskRegistry.configuring(control) {
                    child = configuring.process
                    abort = true
                } else { return .more }

                // The owner is no longer on any list. Its queue link is private
                // until this child finishes and `finish` restores the owner.
                process.pointee.next = pending
                pending = process
                process = child
                parent  = context.processManager.pointee.waitingParent(of: child)
                server  = context.processManager.pointee.beginDeath(
                    child, reason: .killed, aborting: abort, context: context
                )
                waiter         = server?.pointee.replyTo
                previousWaiter = nil
                taskSlot       = 0
                aborting       = abort
                stage          = .outgoingReply
                return .more

            case .children:
                guard let child = process.pointee.family.firstChild else {
                    adoptedTail = nil
                    stage = .replies
                    return .more
                }

                if context.scheduler.pointee.reapChild(child) {
                    context.processManager.pointee.releaseProcess(child)
                    return .more
                }

                let adopter = context.processManager.pointee.initProcess.flatMap { candidate -> UnsafeMutablePointer<Process>? in
                    if case .terminated = candidate.pointee.status { return nil }
                    return candidate
                }
                let newParent = process.pointee.family.parent ?? adopter

                process.pointee.family.removeChild(child)
                child.pointee.family.parent = nil

                if let newParent, newParent != process {
                    if let tail = adoptedTail {
                        child.pointee.family.prevSibling = tail
                        child.pointee.family.nextSibling = tail.pointee.family.nextSibling
                        tail.pointee.family.nextSibling?.pointee.family.prevSibling = child
                        tail.pointee.family.nextSibling = child
                    } else {
                        newParent.pointee.family.pushChild(child)
                    }
                    child.pointee.family.parent = newParent
                    adoptedTail = child
                }
                return .more

            case .replies:
                if let waiter = process.pointee.replyTo {
                    process.pointee.replyTo = waiter.pointee.nextWaiter
                    waiter.pointee.nextWaiter = nil
                    if process.pointee.deferredReplies > 0 { process.pointee.deferredReplies -= 1 }
                    waiter.pointee.context?.pointee.x0 = IPCStatus.peerDied.rawValue
                    context.scheduler.pointee.resume(waiter)
                    return .more
                }

                process.pointee.deferredReplies = 0
                addressSpace = AddressSpaceRelease(
                    process: process,
                    heap   : context.processManager.pointee.heap,
                    vmm    : context.processManager.pointee.vmm
                )
                stage = .addressSpace
                return .more

            case .addressSpace:
                let progress = (try? addressSpace!.step()) ?? .done
                if progress == .done {
                    addressSpace = nil
                    stage = .waits
                }
                return .more

            case .waits:
                context.ipc.pointee.releaseWaits(of: process)
                if let metadata = process.pointee.metadata {
                    capabilities = CapabilityRelease(ipc: context.ipc, metadata: metadata)
                    stage = .capabilities
                } else { stage = .unlink }
                return .more

            case .capabilities:
                if capabilities!.step() == .done {
                    capabilities = nil
                    stage = .unlink
                }
                return .more

            case .unlink:
                guard aborting || parent != nil else {
                    context.scheduler.pointee.addZombie(process)
                    return finish()
                }

                if !aborting {
                    parent?.pointee.context?.pointee.x0 = ProcessManager.exitStatus(of: process)
                }
                context.processManager.pointee.unlinkCorpse(process)
                stage = .metadata
                return .more

            case .metadata:
                context.processManager.pointee.releaseMetadata(of: process)
                stage = .release
                return .more

            case .release:
                context.processManager.pointee.heap.pointee.kfree(process)
                if !aborting, let parent { try? context.scheduler.pointee.wakeUp(parent.pointee.pid) }
                return finish()
        }
    }


    /// Resume the pending owner after the child has stopped using its block.
    /// Its final registry state makes a fresh slot scan skip completed tasks.
    private mutating func finish() -> Progress {
        guard let owner = pending else { return .done }

        pending = owner.pointee.next
        owner.pointee.next = nil
        process = owner
        parent = context.processManager.pointee.waitingParent(of: owner)
        aborting = false
        taskSlot = 0
        stage = .tasks
        return .more
    }
}
