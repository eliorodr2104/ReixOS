//
//  ProcessPreparation.swift
//  ReixOS
//

import ReixABI

/// Each allocation becomes owned by `resources` only when its step succeeds.
/// The caller unwinds that private prefix before publishing any process.
struct ProcessPreparation: ResumableOperation {

    typealias Failure = ProcessManagerError

    struct Resources {
        var metadata    : UnsafeMutablePointer<ProcessMetadata>?
        var addressSpace: AddressSpace?
        var context     : UnsafeMutablePointer<Arch.TrapFrame>?
    }

    let heap      : UnsafeMutablePointer<BucketsHeap>
    let vmm       : UnsafeMutablePointer<VirtualMemoryManager>
    let ppm       : UnsafeMutablePointer<KernelPPM>
    let resources : UnsafeMutablePointer<Resources>
    let frameLimit: UInt32
    let makeContext: Bool
    private var phase = 0

    init(
        heap      : UnsafeMutablePointer<BucketsHeap>,
        vmm       : UnsafeMutablePointer<VirtualMemoryManager>,
        ppm       : UnsafeMutablePointer<KernelPPM>,
        resources : UnsafeMutablePointer<Resources>,
        frameLimit: UInt32,
        makeContext: Bool
    ) {
        self.heap       = heap
        self.vmm        = vmm
        self.ppm        = ppm
        self.resources  = resources
        self.frameLimit = frameLimit
        self.makeContext = makeContext
    }

    mutating func step() throws(ProcessManagerError) -> Progress {
        switch phase {
            case 0:
                guard let metadata = makeMetadata() else { throw .heapAllocationFailed }
                metadata.pointee.budget.pointee.limit = frameLimit
                resources.pointee.metadata = metadata

            case 1:
                do {
                    resources.pointee.addressSpace = try vmm.pointee.createAddressSpace(
                        budget: resources.pointee.metadata!.pointee.budget
                    )
                } catch { throw .creationProcessFailed(error) }

            case 2:
                guard let vma = heap.pointee.kmallocOrNil(VMAManager.self) else {
                    throw .heapAllocationFailed
                }
                let space = resources.pointee.addressSpace!
                vma.initialize(to: VMAManager(
                    heap             : heap,
                    vmm              : vmm,
                    ppm              : ppm,
                    rootTablePhysical: space.rootTablePhysical,
                    asid             : space.asid,
                    budget           : resources.pointee.metadata!.pointee.budget
                ))
                resources.pointee.addressSpace!.vmaManager = vma

            case 3:
                guard makeContext else { return .done }
                guard let context = Self.makeTrapFrame(heap: heap, entry: 0, stack: UserSpaceLayout.stackTop) else {
                    throw .heapAllocationFailed
                }
                resources.pointee.context = context

            default: return .done
        }

        phase += 1
        return .more
    }

    /// Out of line so the metadata temporary dies before the next allocation.
    @inline(never)
    private func makeMetadata() -> UnsafeMutablePointer<ProcessMetadata>? {
        guard let metadata = heap.pointee.kmallocOrNil(ProcessMetadata.self) else { return nil }
        guard let budget = heap.pointee.kmallocOrNil(FrameBudget.self) else {
            heap.pointee.kfree(metadata)
            return nil
        }
        budget.initialize(to: FrameBudget())
        metadata.initialize(to: ProcessMetadata())
        metadata.pointee.budget = budget
        return metadata
    }

    /// The 816-byte temporary must not share a frame with the metadata one.
    @inline(never)
    static func makeTrapFrame(
        heap : UnsafeMutablePointer<BucketsHeap>,
        entry: VirtualAddress,
        stack: VirtualAddress
    ) -> UnsafeMutablePointer<Arch.TrapFrame>? {
        guard let context = heap.pointee.kmallocOrNil(Arch.TrapFrame.self) else { return nil }
        context.initialize(to: Arch.TrapFrame())
        context.pointee.elr   = entry
        context.pointee.spel0 = stack
        return context
    }
}
