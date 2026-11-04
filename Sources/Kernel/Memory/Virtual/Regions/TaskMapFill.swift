//
//  TaskMapFill.swift
//  ReixOS
//

/// `ProcessManager.mapTaskAnonymous`, cut into one step per page so the
/// interrupt window has somewhere to open inside it.
///
/// A step charges one frame to the task, takes it, zeroes it and installs it,
/// and the four happen together or not at all: a refused charge throws before
/// taking anything, a failed allocation gives the charge back, a failed install
/// gives the frame and the charge back. So at every step boundary the pages
/// below `cursor` are mapped, charged and counted and nothing above it is,
/// which is the state `rollbackMapping` undoes when a step throws.
///
/// The region it fills is registered before the first step and the task it
/// belongs to is `.configuring`: in no queue and owned by the caller, so
/// nothing a window lets in can reach either.
struct TaskMapFill: ResumableOperation {

    typealias Failure = PPMError

    private let ppm   : UnsafeMutablePointer<KernelPPM>
    private let vmm   : UnsafeMutablePointer<VirtualMemoryManager>
    private let vma   : UnsafeMutablePointer<VMAManager>
    private let root  : PhysicalAddress
    private let budget: UnsafeMutablePointer<FrameBudget>?

    /// The next page to fill, and the end of the range.
    private var cursor: VirtualAddress
    private let end   : VirtualAddress


    init(
        ppm   : UnsafeMutablePointer<KernelPPM>,
        vmm   : UnsafeMutablePointer<VirtualMemoryManager>,
        vma   : UnsafeMutablePointer<VMAManager>,
        root  : PhysicalAddress,
        budget: UnsafeMutablePointer<FrameBudget>?,
        start : VirtualAddress,
        end   : VirtualAddress
    ) {
        self.ppm    = ppm
        self.vmm    = vmm
        self.vma    = vma
        self.root   = root
        self.budget = budget
        self.cursor = start
        self.end    = end
    }


    mutating func step() throws(PPMError) -> Progress {
        guard cursor < end else { return .done }

        // The pages of a task map are the child's, charged to the child and
        // given back by the caller's rollback or by its teardown.
        guard chargeFrames(budget, 1) else { throw .budgetExceeded }

        let page: PhysicalPage
        do {
            page = try ppm.pointee.alloc(Int(UserSpaceLayout.pageSize))
        } catch {
            refundFrames(budget, 1)
            throw error
        }

        let zero: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(page.address)
        zero.initialize(repeating: 0, count: Int(UserSpaceLayout.pageSize))

        do {
            try vmm.pointee.installUserPage(
                rootTable: root,
                asid     : vma.pointee.context.asid,
                virtual  : cursor,
                physical : page.address,
                flags    : VMAPermissions([.read, .write, .user]).toPageFlags(),
                type     : .normal,
                budget   : budget
            )
        } catch {
            try? ppm.pointee.free(page)
            refundFrames(budget, 1)
            throw error
        }

        vma.pointee.noteMapped(1)
        cursor += UserSpaceLayout.pageSize

        return cursor < end ? .more : .done
    }
}
