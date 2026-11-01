//
//  AddressSpaceRelease.swift
//  ReixOS
//

/// `ProcessManager.releaseAddressSpace` as steps, so the frees that follow the
/// region walk are not one masked stretch tacked onto its end.
///
/// The order is the one the function always had, and every boundary between two
/// stages is a place a window may open:
///
/// 1. the trace export lets go of the process and the VMA list is moved out of
///    the manager, see `VMAManager.retirement`;
/// 2. `ListRetirement`, one batch of pages per step;
/// 3. the emptied manager goes back to the heap, then the trap frame, one step
///    each because a heap free measured up to a step's worth in the diagnostic
///    image;
/// 4. `destroyAddressSpace` frees the tables, then the root, and only then the
///    ASID, after the invalidation of its tag.
///
/// The fourth stage is one step and stays one. What is left of the tables once
/// the retirement has pruned every span it emptied is the root and a handful of
/// pages, and keeping the whole sequence in one function is what lets the
/// `tlb-scope` post-check read detach, invalidate, free, release in the image.
///
/// The walk is stepped here rather than run by `VMAManager.teardown`, so that an
/// operation driving this one opens its windows inside the walk too: a
/// `Preemption.run` nested in another opens none.
struct AddressSpaceRelease: ResumableOperation {

    typealias Failure = PPMError

    private enum Stage {
        case begin
        case regions
        case manager
        case trapFrame
        case tables
    }

    private let process: UnsafeMutablePointer<Process>
    private let heap   : UnsafeMutablePointer<BucketsHeap>
    private let vmm    : UnsafeMutablePointer<VirtualMemoryManager>

    private var stage     : Stage = .begin
    private var retirement: ListRetirement? = nil


    init(
        process: UnsafeMutablePointer<Process>,
        heap   : UnsafeMutablePointer<BucketsHeap>,
        vmm    : UnsafeMutablePointer<VirtualMemoryManager>
    ) {
        self.process = process
        self.heap    = heap
        self.vmm     = vmm
    }


    mutating func step() throws(PPMError) -> Progress {
        switch stage {
            case .begin:
                TraceExport.detach(pid: process.pointee.pid)

                if let manager = process.pointee.addressSpace.vmaManager {
                    retirement = manager.pointee.retirement()
                    stage      = .regions

                } else { stage = .trapFrame }

                return .more

            case .regions:
                if retirement!.step() == .done {
                    retirement = nil
                    stage      = .manager
                }

                return .more

            case .manager:
                // Emptied by the retirement, and walked by nobody from here on.
                if let manager = process.pointee.addressSpace.vmaManager {
                    heap.pointee.kfree(manager)
                    process.pointee.addressSpace.vmaManager = nil
                }

                stage = .trapFrame

                return .more

            case .trapFrame:
                if let metadata = process.pointee.metadata {
                    metadata.pointee.elfImage    = nil
                    metadata.pointee.elfLoadBase = 0
                    metadata.pointee.elfLoadEnd  = 0
                }

                // The process is on no queue that would resume it.
                if let trapFrame = process.pointee.context {
                    heap.pointee.kfree(trapFrame)
                    process.pointee.context = nil
                }

                stage = .tables

                return .more

            case .tables:
                defer { ProcessManager.reinstallCurrentAddressSpace() }

                // The metadata block, and with it the budget, is freed later by
                // `releaseProcess`: the page tables can still be refunded here.
                try vmm.pointee.destroyAddressSpace(
                    addressSpace: process.pointee.addressSpace,
                    budget      : process.pointee.metadata?.pointee.budget
                )

                return .done
        }
    }
}
