//
//  ProcessTeardown.swift
//  ReixOS
//

/// Everything `killProcess` does after the process stops being runnable, as one
/// `ResumableOperation` under `AddressSpaceTeardown`.
///
/// ## Why one operation and not three runs
///
/// The death used to be two runs, the region walk and the capability table, with
/// work no run covered between and after them: the trap frame and the tables
/// freed after the walk, the corpse handed to its parent after the table. A
/// window opens only between two steps of a run, so each of those pieces held
/// the door shut on top of whatever the run before it had last left open. Measured
/// in the diagnostic image on QEMU virt, the exit path's longest stretch was about
/// 0.8 ms and always one of those seams: the last window of the walk to the first
/// of the capability release, or the last of the release to the switch away.
///
/// A run nested in another opens no windows, so the pieces could not simply be
/// wrapped. They are stages of this operation instead, each a step or a sequence
/// of them, and every boundary is a checkpoint. Over the same boots the worst
/// stretch of an `exit` went from a median of 0.65 ms to 0.29 ms, with none of
/// 36 above 0.5 ms; what is left is the budget plus one step, and the prologue
/// of `killProcess` ahead of the run.
///
/// ## The order, which is the one `killProcess` always had
///
/// 1. `AddressSpaceRelease`: regions, then frames, then the tables, the root and
///    last the ASID, after its tag is invalidated.
/// 2. `releaseWaits`, before the table, see `RendezvousIPC.releaseWaits`.
/// 3. `CapabilityRelease`, one held slot per step.
/// 4. The corpse: to the `terminated` list, or to the parent parked in
///    `reapChild` on it, in three steps.
///
/// Every death route ends in the fourth stage (`exit`, a fault, `terminate`, a
/// `split` unwinding its half-built child), because the two outcomes are
/// exclusive and a route that performed neither was doubly broken: the parent
/// parked in `reapChild` was never woken, and the unrecorded `Process` block was
/// left unreachable by any later reap.
///
/// A table the PPM refuses to take back fails the first stage and nothing else,
/// as the `try?` it replaces did: the capabilities still go and the parent is
/// still told.
///
/// ## What a window may find
///
/// The corpse is `.terminated` and on no queue for the whole run, which is
/// what a zombie looks like, so the tick's walk of the family tree reads a
/// zombie until the corpse is unlinked and nothing at all after.
///
/// Its deadlines stay armed until the second stage, as they did under the
/// walk's own windows before this: every expiry leaves a `.terminated` process
/// where it is, and the `Process` block outlives them all.
struct ProcessTeardown: ResumableOperation {

    typealias Failure = Never

    private enum Stage {
        case addressSpace
        case waits
        case capabilities
        case unlink
        case metadata
        case release
    }

    private let process: UnsafeMutablePointer<Process>
    private let parent : UnsafeMutablePointer<Process>?
    private let context: SyscallContext

    private var stage       : Stage = .addressSpace
    private var addressSpace: AddressSpaceRelease
    private var capabilities: CapabilityRelease? = nil


    /// - Parameter parent: the process parked in `reapChild` on this one, or
    ///   `nil` to leave the corpse on the `terminated` list.
    init(
        process: UnsafeMutablePointer<Process>,
        parent : UnsafeMutablePointer<Process>?,
        context: SyscallContext
    ) {
        self.process      = process
        self.parent       = parent
        self.context      = context
        self.addressSpace = AddressSpaceRelease(
            process: process,
            heap   : context.processManager.pointee.heap,
            vmm    : context.processManager.pointee.vmm
        )
    }


    mutating func step() -> Progress {
        switch stage {
            case .addressSpace:
                // A refused free ends this stage, as the `try?` it replaces did,
                // and not the death.
                let progress = (try? addressSpace.step()) ?? .done

                if progress == .done { stage = .waits }

                return .more

            case .waits:
                context.ipc.pointee.releaseWaits(of: process)

                if let metadata = process.pointee.metadata {
                    capabilities = CapabilityRelease(ipc: context.ipc, metadata: metadata)
                    stage        = .capabilities

                } else { stage = .unlink }

                return .more

            case .capabilities:
                if capabilities!.step() == .done { stage = .unlink }

                return .more

            case .unlink:
                guard let parent else {
                    context.scheduler.pointee.addZombie(process)
                    return .done
                }

                // Read before `releaseMetadata` frees the block it lives in.
                parent.pointee.context?.pointee.x0 = ProcessManager.exitStatus(of: process)

                context.processManager.pointee.unlinkCorpse(process)
                stage = .metadata

                return .more

            case .metadata:
                context.processManager.pointee.releaseMetadata(of: process)
                stage = .release

                return .more

            case .release:
                context.processManager.pointee.heap.pointee.kfree(process)

                // Only now: `unlinkCorpse` cleared the parent's `waitingChildPid`,
                // and a parent resumed still claiming it would walk a freed block.
                try? context.scheduler.pointee.wakeUp(parent!.pointee.pid)

                return .done
        }
    }
}
