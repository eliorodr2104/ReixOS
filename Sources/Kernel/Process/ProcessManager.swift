//
//  ProcessManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/04/2026.
//

import ReixABI

/// Owns the lifecycle of every kernel-managed process.
///
/// Built as an instance struct so its mutable state (PID counter, injected
/// VMM/PPM/Heap pointers) is explicit and testable. The single live
/// instance is composed by `Kernel.boot` and reached through
/// `Kernel.processManager`.
public struct ProcessManager: RXAllocatable, Loggable {

    public static var errorMessageAllocation: StaticString = "Failed to allocate ProcessManager on the kernel heap"
    
    public static let nameLog : StaticString = "[PROC]"
    public static let logLevel: LogLevel     = .info
    
    /// Bytes of a path `assignName` is willing to walk looking for its end.
    private static let maxPathScan: Int = 256
    
    /// Monotonically increasing PID source. Never reused within a boot.
    ///
    /// Starts at 1 for the same reason `identityCounter` does: `0` is what a
    /// trace record stamps for "no process" (the kernel and the idle loop),
    /// and it is the exclusive cursor `procStats` sweeps start from, so a
    /// process numbered 0 would be unattributable in one and unreachable in
    /// the other.
    private var pidCounter: PID = 1

    /// Monotonically increasing source of `Process.identity`, kept apart from
    /// `pidCounter` on purpose.
    ///
    /// Starts at 1 because `0` is the wire value for "no identity": a process
    /// holding it would be indistinguishable, to every server keying state on the
    /// badge, from a message carrying no principal at all. Counting separately
    /// from the PID is what keeps identities from aliasing if PIDs are ever
    /// reused, see `Process.identity`.
    private var identityCounter: Identity = 1


    /// The next pid and the next identity, or nothing when there are no more.
    ///
    /// One place, because there were two and both did `+= 1` on a counter with a
    /// top. Monotonic and never reused is the contract - see
    /// `ProcessManagerError.identitiesExhausted` - so running out is a refusal
    /// this has to be able to say, and the alternative was arithmetic that traps
    /// half way through building a process.
    ///
    /// Nothing is consumed unless both are available, so a refusal here leaves
    /// the counters exactly where it found them.
    private mutating func nextIdentifiers() -> (pid: PID, identity: Identity)? {

        guard pidCounter < PID.max, identityCounter < Identity.max else { return nil }

        let pid      = pidCounter
        let identity = identityCounter

        pidCounter      += 1
        identityCounter += 1

        return (pid, identity)
    }

    /// Root of the process tree, published once by `Kernel.jumpUserLand`.
    ///
    /// `killProcess` needs a fallback adopter for the children of a process
    /// that has no parent of its own, otherwise they would keep pointing at
    /// the struct we are about to free. Init is never a child of anybody, so
    /// no `removeChild(id:)`/`findChild(id:)` lookup can ever reach it and no
    /// `releaseProcess` path can free it: this pointer stays valid for the
    /// whole boot.
    public internal(set) var initProcess: UnsafeMutablePointer<Process>? = nil

    let vmm               : UnsafeMutablePointer<VirtualMemoryManager>
    let ppm               : UnsafeMutablePointer<KernelPPM>
    let heap              : UnsafeMutablePointer<BucketsHeap>
    private let fileSystem: UnsafeMutablePointer<TarFileSystem>
    
    
    public init(
        vmm       : UnsafeMutablePointer<VirtualMemoryManager>,
        ppm       : UnsafeMutablePointer<KernelPPM>,
        heap      : UnsafeMutablePointer<BucketsHeap>,
        fileSystem: UnsafeMutablePointer<TarFileSystem>
    ) {
        self.vmm        = vmm
        self.ppm        = ppm
        self.heap       = heap
        self.fileSystem = fileSystem

        Self.boot("Process Manager ready.")
    }
    
    
    /// Loads `path` and builds a runnable process out of it: address space, VMA
    /// manager, ELF segments, first stack page, trap frame, metadata, `Process`.
    ///
    /// ## Unwinding a half-built process
    ///
    /// Every step below has to undo the blocks allocated before it, innermost
    /// first, and only then the address space. What makes that tractable is that
    /// everything mapped along the way, the ELF segments and the first stack
    /// page, carries a registered VMA: the VMA list is the only thing
    /// `destroyPartialAddressSpace` can see, because walking it is all it does.
    /// No step past the stack mapping maps a page, so the invariant holds on
    /// every rung of the ladder.
    public mutating func spawnProcess(path: UnsafePointer<CChar>) throws(ProcessManagerError) -> UnsafeMutablePointer<Process> {
        
        // A refused open and a missing member look the same to the caller: no
        // image to load.
        let handle: FileHandle
        do {
            handle = try fileSystem.pointee.open(path: path, flags: .read)
        } catch {
            throw .elfParsingFailed(.invalidMagicNumber)
        }

        defer { try? fileSystem.pointee.close(handle: handle) }

        let prepared = try prepareProcess(frameLimit: childFrameLimit(), makeContext: false)
        let metadataPtr = prepared.metadata!
        Self.assignName(metadataPtr, basenameOf: path)

        let budget = metadataPtr.pointee.budget
        var addressSpace = prepared.addressSpace!
        let vmaManagerPtr = addressSpace.vmaManager!

        let elf: LoadedELF
        do {
            elf = try ElfParser.loadSegments(
                handle: handle, fileSystem: fileSystem,
                addressSpace: addressSpace, vmaManager: vmaManagerPtr,
                vmm: vmm, ppm: ppm
            )
        } catch {
            discardPreparation(prepared)
            throw .elfParsingFailed(error)
        }

        let userStackTop   = UserSpaceLayout.stackTop
        let firstStackPage = userStackTop - UserSpaceLayout.pageSize

        guard chargeFrames(budget, 1) else {
            destroyPartialAddressSpace(&addressSpace, budget: budget)
            freeMetadata(metadataPtr)
            throw .allocationPageFailed(.budgetExceeded)
        }

        let stackPage: PhysicalPage
        do {
            stackPage = try ppm.pointee.alloc(4096)
        } catch {
            refundFrames(budget, 1)
            destroyPartialAddressSpace(&addressSpace, budget: budget)
            freeMetadata(metadataPtr)
            throw .allocationPageFailed(error)
        }

        let stackBytes: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(
            stackPage.address
        )
        stackBytes.initialize(
            repeating: 0,
            count    : Int(UserSpaceLayout.pageSize)
        )

        do {
            try vmm.pointee.installUserPage(
                addressSpace: addressSpace,
                virtual     : firstStackPage,
                physical    : stackPage.address,
                flags       : [.present, .userAccess, .pxn, .uxn],
                type        : .normal,
                budget      : budget
            )
        } catch {
            try? ppm.pointee.release(stackPage.address)
            refundFrames(budget, 1)
            destroyPartialAddressSpace(&addressSpace, budget: budget)
            freeMetadata(metadataPtr)
            throw .mappingFailed(error)
        }

        do {
            try vmaManagerPtr.pointee.registerRegion(
                start      : firstStackPage,
                size       : UserSpaceLayout.pageSize,
                permissions: [.read, .write, .user],
                backing    : .anonymous,
                flags      : .growDown,
                memoryType : .normal
            )
        } catch {
            try? ppm.pointee.release(stackPage.address)
            refundFrames(budget, 1)
            destroyPartialAddressSpace(&addressSpace, budget: budget)
            freeMetadata(metadataPtr)
            throw .registerRegionError(error)
        }

        // Nothing below maps a page, which is what keeps the unwinding
        // rule on `spawnProcess` true for every step from here down.
        guard let trapFramePtr = ProcessPreparation.makeTrapFrame(
            heap: heap, entry: elf.entryPoint, stack: userStackTop
        
        ) else {
            destroyPartialAddressSpace(&addressSpace, budget: budget)
            freeMetadata(metadataPtr)
            throw .heapAllocationFailed
        }

        guard let numbered = self.nextIdentifiers() else {
            heap.pointee.kfree(trapFramePtr)
            destroyPartialAddressSpace(&addressSpace, budget: budget)
            freeMetadata(metadataPtr)
            throw .identitiesExhausted
        }

        let pid      = numbered.pid
        let identity = numbered.identity

        let initialBreak = (elf.loadEnd + UserSpaceLayout.pageSize - 1) & ~(UserSpaceLayout.pageSize - 1)

        metadataPtr.pointee.elfImage     = elf.image
        metadataPtr.pointee.elfLoadBase  = elf.loadBase
        metadataPtr.pointee.elfLoadEnd   = elf.loadEnd
        metadataPtr.pointee.programBreak = initialBreak

        guard let processPtr = makeProcess(
            pid         : pid,
            identity    : identity,
            addressSpace: addressSpace,
            context     : trapFramePtr,
            metadata    : metadataPtr
        
        ) else {
            heap.pointee.kfree(trapFramePtr)
            destroyPartialAddressSpace(&addressSpace, budget: budget)
            freeMetadata(metadataPtr)
            throw .heapAllocationFailed
        }

        guard Self.registerForProcStats(processPtr) else {
            Arch.CPU.panic("duplicate process in ProcStats index")
        }

        vmaManagerPtr.pointee.setInitialBreak(initialBreak)

        vmaManagerPtr.pointee.recountResidentPages()

        Self.traceSpawn(pid)
        Self.traceName(metadataPtr, pid: pid)

        return processPtr
    }
    
    
    /// - Parameter frameLimit: what the creator asks the child be allowed to
    ///   hold, clamped to the creator's own limit. `nil` inherits it whole.
    public mutating func spawnProcess(
        name      : InlineArray<16, UInt8>? = nil,
        nameLength: Int = 0,
        frameLimit: UInt32? = nil
    ) throws(ProcessManagerError) -> UnsafeMutablePointer<Process> {

        let prepared = try prepareProcess(
            frameLimit : childFrameLimit(requesting: frameLimit),
            makeContext: true
        )
        let metadataPtr = prepared.metadata!
        let budget = metadataPtr.pointee.budget
        var addressSpace = prepared.addressSpace!
        let trapFramePtr = prepared.context!

        if let parent = Arch.CPU.getCurrentProcess()?.pointee.metadata {
            metadataPtr.pointee.setName(copyingFrom: parent)
        }
        if var name {
            withUnsafeBytes(of: &name) { bytes in
                metadataPtr.pointee.setName(
                    from : bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    count: nameLength
                )
            }
        }

        guard let numbered = self.nextIdentifiers() else {
            heap.pointee.kfree(trapFramePtr)
            destroyPartialAddressSpace(&addressSpace, budget: budget)
            freeMetadata(metadataPtr)
            throw .identitiesExhausted
        }

        let pid      = numbered.pid
        let identity = numbered.identity

        guard let processPtr = makeProcess(
            pid         : pid,
            identity    : identity,
            addressSpace: addressSpace,
            context     : trapFramePtr,
            metadata    : metadataPtr
        
        ) else {
            heap.pointee.kfree(trapFramePtr)
            destroyPartialAddressSpace(&addressSpace, budget: budget)
            freeMetadata(metadataPtr)
            throw .heapAllocationFailed
        }


        guard Self.registerForProcStats(processPtr) else {
            Arch.CPU.panic("duplicate process in ProcStats index")
        }

        Self.traceSpawn(pid)
        Self.traceName(metadataPtr, pid: pid)

        return processPtr
    }
    
    
    /// Keep the allocations private across windows, and unwind their completed
    /// prefix while its budget cell is still alive if any step refuses.
    private func prepareProcess(
        frameLimit : UInt32,
        makeContext: Bool
    ) throws(ProcessManagerError) -> ProcessPreparation.Resources {
        var resources = ProcessPreparation.Resources()
        do {
            try withUnsafeMutablePointer(to: &resources) { storage throws(ProcessManagerError) in
                _ = try Preemption.run(ProcessCreation.self, ProcessPreparation(
                    heap       : heap,
                    vmm        : vmm,
                    ppm        : ppm,
                    resources  : storage,
                    frameLimit : frameLimit,
                    makeContext: makeContext
                ))
            }
        } catch {
            discardPreparation(resources)
            throw error
        }
        return resources
    }


    /// The same unwind serves a refused allocation and a refused image copy.
    /// The budget must outlive every page that is returned through it.
    func discardPreparation(_ resources: ProcessPreparation.Resources) {
        if let context = resources.context { heap.pointee.kfree(context) }
        if var space = resources.addressSpace {
            destroyPartialAddressSpace(&space, budget: resources.metadata?.pointee.budget)
        }
        if let metadata = resources.metadata { freeMetadata(metadata) }
    }


    /// Tears `process`'s address space down in one run of the teardown region.
    ///
    /// For the callers that release an address space on its own: an abort, a
    /// spawn unwinding its child. A death runs `AddressSpaceRelease` as the first
    /// stage of `ProcessTeardown` instead, inside that operation's one run.
    public func releaseAddressSpace(_ process: UnsafeMutablePointer<Process>) throws(PPMError) {
        _ = try Preemption.run(
            AddressSpaceTeardown.self,
            AddressSpaceRelease(process: process, heap: heap, vmm: vmm)
        )
    }


    /// Put the running process's root back in TTBR0 after another address
    /// space has been torn down.
    ///
    /// `destroyAddressSpace` has to detach the root it is about to free, and it
    /// does so by installing the kernel identity root. That is right when the
    /// caller is dying, since `beginDeath` clears the current process first and
    /// the scheduler installs whoever runs next, but every other caller is a live
    /// process destroying *somebody else's* space: a parent in `terminate`, or a
    /// failed `spawn`/`split` unwinding its half-built child. Those return
    /// straight to EL0, and the identity root carries no user mapping at all, so
    /// the caller would fault on its own next instruction, fault again servicing
    /// it into a root that is not installed, and never make progress.
    ///
    /// A nil current process is therefore the signal to leave TTBR0 alone; it is
    /// the only case where the outgoing root was the running one.
    @inline(__always)
    static func reinstallCurrentAddressSpace() {
        guard let current = Arch.CPU.getCurrentProcess() else { return }

        Arch.MMU.switchUserAddressSpace(
            current.pointee.addressSpace.rootTablePhysical,
            asid: current.pointee.addressSpace.asid
        )
    }

    /// Final teardown of a process struct after every consumer has read
    /// the exit code from its metadata. Frees the metadata block and the
    /// `Process` struct itself. Callers must ensure the process is no
    /// longer referenced by any scheduler queue.
    ///
    /// Three pieces, because `ProcessTeardown` takes them as three steps and a
    /// window between two of them must find a consistent corpse.
    public func releaseProcess(_ process: UnsafeMutablePointer<Process>) {
        unlinkCorpse(process)
        releaseMetadata(of: process)
        heap.pointee.kfree(process)
    }


    /// Takes the corpse out of every enumeration: the stats index, the trace
    /// export and its parent's children, and clears a parent's wait on it.
    /// What is left is reachable only through the pointer the caller holds.
    func unlinkCorpse(_ process: UnsafeMutablePointer<Process>) {

        guard Self.unregisterForProcStats(process) else {
            Arch.CPU.panic("missing process in ProcStats index")
        }

        TraceExport.detach(pid: process.pointee.pid)

        if let parent = process.pointee.family.parent {
            parent.pointee.family.removeChild(process)

            if let parentMeta = parent.pointee.metadata,
               parentMeta.pointee.waitingChildPid == process.pointee.pid {

                parentMeta.pointee.waitingChildPid = nil
            }
        }
    }


    /// Frees the metadata block, and the budget with it once nobody else holds
    /// it, after telling the task registry the process is gone.
    func releaseMetadata(of process: UnsafeMutablePointer<Process>) {
        guard let metadata = process.pointee.metadata else { return }

        if let control = metadata.pointee.taskControl {
            TaskRegistry.markProcessGone(control)
        }

        freeMetadata(metadata)
        process.pointee.metadata = nil
    }


    /// Decodes the status a parent observes when it reaps this corpse.
    ///
    /// `exitReason` is the only field that records how a process died. The
    /// dying process's `x0` carries the code on the `exit(code)` route alone;
    /// on a fault or a `terminate` it is whatever user register happened to be
    /// live, so reading it as a status is reading noise. Both reaps, the
    /// synchronous one, where the child is already a zombie, and the
    /// asynchronous one, where the parent blocks first and the child dies
    /// later, go through this single decoder, so one death can never be
    /// reported to the parent as two different numbers.
    public static func exitStatus(of process: UnsafeMutablePointer<Process>) -> ExitCode {

        guard case .exited(let code)? = process.pointee.metadata?.pointee.exitReason else {
            return 0
        }

        return code
    }


    // ProcessManager
    public func killCurrent(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        reason : ExitReason,
        context: SyscallContext
    ) {
        if let oldProcess = Arch.CPU.getCurrentProcess() {
            killProcess(oldProcess, reason: reason, context: context)
        }

        leaveDeadCaller(frame: frame, context: context)
    }


    /// Puts the next ready process in `frame`, or idles, for a trap whose caller
    /// is dead and off the CPU. Nothing else may be written to `frame` after this.
    func leaveDeadCaller(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        if let trapFrame = context.scheduler.pointee.yield() {
            if let next = Arch.CPU.getCurrentProcess() {
                
                Arch.MMU.switchUserAddressSpace(
                    next.pointee.addressSpace.rootTablePhysical,
                    asid: next.pointee.addressSpace.asid
                )
            }
            
            Arch.TrapFrame.copy(from: trapFrame, to: frame)
            
        } else {
            Arch.CPU.setCurrentProcess(0)

            // The idle loop never returns to the exception's exit.
            IrqOffStretch.close(at: Arch.Timer.counterUnordered())
            Arch.CPU.idleLoop()
        }
    }
    
    /// Tears a process down and disposes of its corpse.
    ///
    /// Returns `true` while the corpse is still reachable, parked on the
    /// scheduler's `terminated` list, so a caller that wants it may reap and
    /// release it. Returns `false` when it went to a parent already blocked in
    /// `reapChild`: that hand-off frees the `Process` block, so `process` is
    /// dangling on return and must not be touched again.
    ///
    /// The death may take the running process with it, as `process` or as a
    /// task it owns at any depth, which a delegated job allows. `beginDeath`
    /// then clears the CPU, and the caller must leave through
    /// `leaveDeadCaller` instead of returning to user mode.
    @discardableResult
    public func killProcess(
        _ process: UnsafeMutablePointer<Process>,
          reason : ExitReason,
          context: SyscallContext
    ) -> Bool {

        if case .terminated = process.pointee.status {
            return context.scheduler.pointee.search(in: .terminated, to: process.pointee.pid) == process
        }

        let parent = waitingParent(of: process)
        let server = beginDeath(process, reason: reason, context: context)

        _ = Preemption.run(
            AddressSpaceTeardown.self,
            ProcessTeardown(process: process, parent: parent, server: server, context: context)
        )

        return parent == nil
    }


    /// Publishes death before any window, with no walk over another process.
    ///
    /// `terminated` means no longer live, not yet on the zombie queue. Resume,
    /// deadline expiry and identity lookup already refuse that state. Reaping
    /// additionally proves queue membership, so an unfinished death is not a
    /// corpse a parent can free. The outgoing reply link is walked in steps;
    /// its server stays alive until that walk ends, before any owned task dies.
    ///
    /// The running process stops being current here, however the death reached
    /// it, so no window and no later step sees a dead process on the CPU.
    func beginDeath(
        _ process: UnsafeMutablePointer<Process>,
        reason   : ExitReason,
        aborting : Bool = false,
        context  : SyscallContext
    ) -> UnsafeMutablePointer<Process>? {
        let status = process.pointee.status
        let server = process.pointee.replyPartner

        if process == Arch.CPU.getCurrentProcess() { Arch.CPU.setCurrentProcess(0) }

        SleepSyscall.unpark(pid: process.pointee.pid)
        _ = KernelDeadlineQueue.shared.cancel(process)

        if let set = InterruptClaims.set(waitedOnBy: process) {
            set.pointee.waiter = nil
        }

        switch status {
            case .blockedOnSend(let endpoint?), .blockedOnReceive(let endpoint?):
                endpoint.pointee.queue.remove(element: process)
                if endpoint.pointee.queue.isEmpty() { endpoint.pointee.state = .idle }

            case .ready, .waiting:
                context.scheduler.pointee.unlink(process, in: status)

            default: break
        }

        process.pointee.status                       = .terminated
        process.pointee.metadata?.pointee.exitReason = reason

        if let control = process.pointee.metadata?.pointee.taskControl {
            releaseConstruction(aborting
                ? TaskRegistry.markAborted(control)
                : TaskRegistry.markExited(control, code: Self.exitStatus(of: process)))
        }

        Trace.emit(
            TraceProc.self,
            code: TraceCode.procExit,
            info: Self.traceReason(reason),
            a   : process.pointee.pid
        )

        return server
    }

    /// `releaseCapabilities` as steps of the teardown region, for `abortTask`: a
    /// window can open after any held slot, so a table full of endpoints and
    /// regions is not one masked stretch added to the abort. The region is the
    /// teardown's because it is the same constraint: nobody left to resume.
    /// `killProcess` runs the same two pieces as stages of `ProcessTeardown`.
    func releaseCapabilitiesInSteps(
        of process: UnsafeMutablePointer<Process>,
        _  context: SyscallContext
    ) {
        context.ipc.pointee.releaseWaits(of: process)

        guard let metadata = process.pointee.metadata else { return }

        _ = Preemption.run(
            AddressSpaceTeardown.self,
            CapabilityRelease(ipc: context.ipc, metadata: metadata)
        )
    }


    /// The parent parked in `reapChild` on this very process, which the corpse
    /// is handed to, or `nil` when it goes to the `terminated` list instead.
    ///
    /// Asked before the teardown runs rather than after it, so `killProcess` can
    /// still say which of the two happened once the operation is consumed. The
    /// answer cannot change in between: a parent blocked in `reapChild` is on
    /// no endpoint and under no deadline, so neither a window's interrupt nor the
    /// release of this process's capabilities can resume it.
    func waitingParent(
        of process: UnsafeMutablePointer<Process>
    ) -> UnsafeMutablePointer<Process>? {

        guard let parent     = process.pointee.family.parent,
              let parentMeta = parent.pointee.metadata,
              parentMeta.pointee.waitingChildPid == process.pointee.pid
        else { return nil }

        return parent
    }

    /// Visits every process in the family tree, zombies included.
    ///
    /// The tree is the one enumeration that sees a process wherever it is
    /// parked: the scheduler's queues miss whoever is blocked on an endpoint,
    /// and endpoint queues are not reachable from here. Pre-order without
    /// recursion, climbing back up through `parent` links, so a deep tree
    /// costs no kernel stack. `body` must not mutate the tree.
    public func forEachProcess(_ body: (UnsafeMutablePointer<Process>) -> Void) {
        guard let root = initProcess else { return }

        var current: UnsafeMutablePointer<Process>? = root

        while let node = current {
            body(node)
            current = successor(of: node, root: root)
        }
    }


    /// Whether the principal `identity` names is still running.
    ///
    /// The one question a server keying state on a badge could not ask. It is
    /// answerable at all only because identities are never reused within a
    /// boot: a badge naming nothing that runs names nothing for the rest of the
    /// boot, so `false` cannot go stale in the caller's hand.
    ///
    /// A zombie is dead here. Its address space is down and its capabilities are
    /// released before it reaches the `terminated` list, so a server still
    /// holding a window on its behalf is holding it for nobody. A corpse already
    /// reaped is out of the tree entirely, which is the same answer by a
    /// different road: absence is death.
    public func isAlive(identity: Identity) -> Bool {

        // Zero is the wire value for "no principal", so nothing is alive under
        // it and no table can be swept by asking about it.
        guard identity != 0 else { return false }

        var alive = false

        forEachProcess { process in
            guard process.pointee.identity == identity else { return }
            if case .terminated = process.pointee.status { return }

            alive = true
        }

        return alive
    }

    @inline(__always)
    @discardableResult
    static func registerForProcStats(_ process: UnsafeMutablePointer<Process>) -> Bool {
        ProcessStatsIndex.insert(process)
    }

    @inline(__always)
    @discardableResult
    static func unregisterForProcStats(_ process: UnsafeMutablePointer<Process>) -> Bool {
        ProcessStatsIndex.remove(process)
    }

    @discardableResult
    func forEachProcess(
        upTo limit: UInt32,
        _ body: (UnsafeMutablePointer<Process>) -> Void
    ) -> UInt32 {
        ProcessTreeTraversal.forEach(from: initProcess, upTo: limit, body)
    }


    /// Pre-order successor: first child, else the nearest next sibling found
    /// while climbing toward `root`, else nil when the walk is done.
    private func successor(
        of   node: UnsafeMutablePointer<Process>,
        root     : UnsafeMutablePointer<Process>
    ) -> UnsafeMutablePointer<Process>? {

        if let child = node.pointee.family.firstChild { return child }

        var climber: UnsafeMutablePointer<Process>? = node

        while let at = climber, at != root {
            if let sibling = at.pointee.family.nextSibling { return sibling }

            climber = at.pointee.family.parent
        }

        return nil
    }


    // MARK: - Trace funnels

    /// Files a `procSpawn` for a process that is fully built.
    ///
    /// The parent reported is whoever was running at the time, not
    /// `family.parent`: the link is assigned by the caller after this returns,
    /// so at this point the child has none, and the process that asked is the
    /// answer every profile of a spawn actually wants. It is zero for `Init`,
    /// which the kernel spawns with nobody running.
    @inline(__always)
    private static func traceSpawn(_ pid: PID) {
        Trace.emit(
            TraceProc.self,
            code: TraceCode.procSpawn,
            a   : pid,
            b   : Arch.CPU.getCurrentProcess()?.pointee.pid ?? 0
        )
    }


    /// Files the `procName` that pairs with a spawn.
    ///
    /// The pid is passed rather than stamped, because the record describes the
    /// process being created and not the one that asked: without the override
    /// every name in the ring would be attributed to the caller, and the two are
    /// never the same process.
    ///
    /// Both payload words are packed whole, the bytes past `nameLength`
    /// included, which costs nothing because `setName` zeroes that tail: the
    /// decoder reads sixteen bytes and trims by the length instead of scanning.
    @inline(__always)
    private static func traceName(
        _ metadata: UnsafeMutablePointer<ProcessMetadata>,
        pid       : PID
    ) {
        let name = metadata.pointee.name

        var low : UInt64 = 0
        var high: UInt64 = 0

        for index in 0..<8 {
            low  |= UInt64(name[index])     << (8 &* index)
            high |= UInt64(name[index + 8]) << (8 &* index)
        }

        Trace.emit(
            TraceProc.self,
            code: TraceCode.procName,
            info: UInt16(metadata.pointee.nameLength),
            a   : low,
            b   : high,
            pid : UInt32(truncatingIfNeeded: pid)
        )
    }


    /// What a child this process creates may hold, attenuated against what the
    /// creator itself may.
    ///
    /// Monotone by construction: a request above the creator's ceiling is
    /// clamped rather than refused, so no subtree can exceed its root and
    /// nothing has to sum one. With nobody running this is Init, and its ceiling
    /// is the machine minus the kernel's progress reserve.
    private func childFrameLimit(requesting requested: UInt32? = nil) -> UInt32 {

        guard let metadata = Arch.CPU.getCurrentProcess()?.pointee.metadata,
              let budget   = metadata.pointee.budget
        else {
            let machine = ppm.pointee.totalPages > KernelPPM.reservePages
                ? ppm.pointee.totalPages - KernelPPM.reservePages
                : 0

            return UInt32(truncatingIfNeeded: machine)
        }

        return budget.pointee.attenuated(to: requested)
    }


    /// Give back a metadata block a spawn is unwinding, budget cell and all.
    ///
    /// The budget is reference counted, so a plain `kfree` of the block that
    /// names it leaks one slab block per failed spawn.
    private func freeMetadata(_ metadata: UnsafeMutablePointer<ProcessMetadata>) {
        if let budget = metadata.pointee.budget {
            releaseBudget(budget, heap: heap)
        }

        heap.pointee.kfree(metadata)
    }


    /// Keep the initializer temporary off the caller frame, whose live
    /// allocations already span process preparation and image loading.
    @inline(never)
    private mutating func makeProcess(
        pid         : PID,
        identity    : Identity,
        addressSpace: AddressSpace,
        context     : UnsafeMutablePointer<Arch.TrapFrame>,
        metadata    : UnsafeMutablePointer<ProcessMetadata>
    ) -> UnsafeMutablePointer<Process>? {

        guard let ptr = heap.pointee.kmallocOrNil(Process.self) else { return nil }

        ptr.initialize(to: Process(
            pid: pid, identity: identity, addressSpace: addressSpace,
            context: context, metadata: metadata
        ))

        return ptr
    }


    private static func assignName(
        _ metadata     : UnsafeMutablePointer<ProcessMetadata>,
        basenameOf path: UnsafePointer<CChar>
    ) {
        let bytes = UnsafeRawPointer(path).assumingMemoryBound(to: UInt8.self)

        var end   = 0
        var start = 0

        while end < Self.maxPathScan, bytes[end] != 0 {
            if bytes[end] == UInt8(ascii: "/") { start = end + 1 }

            end += 1
        }

        metadata.pointee.setName(
            from : bytes + start,
            count: end - start
        )
    }


    /// How a process died, as `TraceCode.procExit`'s `info`.
    ///
    /// Numbered from one so that zero stays available for "not recorded", and
    /// deliberately not `ExitReason`'s payload: a code or a fault cause is a
    /// second dimension, and the ring records what kind of death it was.
    @inline(__always)
    private static func traceReason(_ reason: ExitReason) -> UInt16 {
        switch reason {
            case .exited            : 1
            case .killed            : 2
            case .memoryFault       : 3
            case .illegalInstruction: 4
            case .stackOverflow     : 5
            case .outOfMemory       : 6
        }
    }


    private func destroyPartialAddressSpace(
        _ space: inout AddressSpace,
        budget : UnsafeMutablePointer<FrameBudget>?
    ) {
        
        if let vma = space.vmaManager {
            vma.pointee.teardown()
            heap.pointee.kfree(vma)
            
            space.vmaManager = nil
        }
        
        try? vmm.pointee.destroyAddressSpace(addressSpace: space, budget: budget)

        Self.reinstallCurrentAddressSpace()
    }
}
