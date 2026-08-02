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
public struct ProcessManager: RXAllocatable {

    public static var errorMessageAllocation: StaticString = "Failed to allocate ProcessManager on the kernel heap"
    
    /// Monotonically increasing PID source. Never reused within a boot.
    private var pidCounter: PID = 0

    /// Monotonically increasing source of `Process.identity`, kept apart from
    /// `pidCounter` on purpose.
    ///
    /// Starts at 1 because `0` is the wire value for "no identity": a process
    /// holding it would be indistinguishable, to every server keying state on the
    /// badge, from a message carrying no principal at all. Counting separately
    /// from the PID is what keeps identities from aliasing if PIDs are ever
    /// reused — see `Process.identity`.
    private var identityCounter: Badge = 1

    /// Root of the process tree, published once by `Kernel.jumpUserLand`.
    ///
    /// `killProcess` needs a fallback adopter for the children of a process
    /// that has no parent of its own, otherwise they would keep pointing at
    /// the struct we are about to free. Init is never a child of anybody, so
    /// no `removeChild(id:)`/`findChild(id:)` lookup can ever reach it and no
    /// `releaseProcess` path can free it: this pointer stays valid for the
    /// whole boot.
    public internal(set) var initProcess: UnsafeMutablePointer<Process>? = nil

    private let vmm       : UnsafeMutablePointer<VirtualMemoryManager>
    private let ppm       : UnsafeMutablePointer<KernelPPM>
    private let heap      : UnsafeMutablePointer<BucketsHeap>
    private let fileSystem: UnsafeMutablePointer<KernelInternalFileSystem>
    
    
    public init(
        vmm       : UnsafeMutablePointer<VirtualMemoryManager>,
        ppm       : UnsafeMutablePointer<KernelPPM>,
        heap      : UnsafeMutablePointer<BucketsHeap>,
        fileSystem: UnsafeMutablePointer<KernelInternalFileSystem>
    ) {
        self.vmm        = vmm
        self.ppm        = ppm
        self.heap       = heap
        self.fileSystem = fileSystem
    }
    
    
    public mutating func spawnProcess(path: UnsafePointer<CChar>) throws(ProcessManagerError) -> UnsafeMutablePointer<Process> {
        
        switch fileSystem.pointee.open(
            path : path,
            flags: .read
        ) {
                
            case .success(let handle):
                defer { _ = fileSystem.pointee.close(handle: handle) }

                var addressSpace: AddressSpace
                do {
                    addressSpace = try vmm.pointee.createAddressSpace()
                } catch { throw .creationProcessFailed(error) }

                guard let vmaManagerPtr = attachVMAManager(to: &addressSpace) else {
                    // Only the fresh root table is live at this point, and
                    // `vmaManager` is still `nil`, so the partial teardown
                    // reduces to destroying the address space.
                    destroyPartialAddressSpace(&addressSpace)
                    throw .heapAllocationFailed
                }

                let elf: LoadedELF
                do {
                    elf = try ElfParser.loadSegments(
                        handle: handle, fileSystem: fileSystem,
                        addressSpace: addressSpace, vmaManager: vmaManagerPtr,
                        vmm: vmm, ppm: ppm
                    )
                } catch {
                    destroyPartialAddressSpace(&addressSpace)
                    throw .elfParsingFailed(error)
                }

                let userStackTop   = UserSpaceLayout.stackTop
                let firstStackPage = userStackTop - UserSpaceLayout.pageSize

                let stackPage: PhysicalPage
                do {
                    stackPage = try ppm.pointee.alloc(4096)
                } catch {
                    destroyPartialAddressSpace(&addressSpace)
                    throw .allocationPageFailed(error)
                }

                do {
                    try vmm.pointee.mapUserPage(
                        addressSpace: addressSpace,
                        virtual     : firstStackPage,
                        physical    : stackPage.address,
                        flags       : [.present, .userAccess, .pxn, .uxn]
                    )
                } catch {
                    try? ppm.pointee.release(stackPage.address)
                    destroyPartialAddressSpace(&addressSpace)
                    throw .mappingFailed(error)
                }

                do {
                    try vmaManagerPtr.pointee.registerRegion(
                        start      : firstStackPage,
                        size       : UserSpaceLayout.pageSize,
                        permissions: [.read, .write, .user],
                        backing    : .anonymous,
                        flags      : .growDown
                    )
                } catch {
                    try? ppm.pointee.release(stackPage.address)
                    destroyPartialAddressSpace(&addressSpace)
                    throw .registerRegionError(error)
                }

                // From here on every failure has to undo the blocks allocated
                // before it, innermost first, and only then the address space.
                // Everything mapped so far — the ELF segments and the first
                // stack page — carries a registered VMA, which is the only thing
                // `destroyPartialAddressSpace` can see: it walks the VMA list.
                // Nothing below maps a page, so that stays true on every rung.
                guard let trapFramePtr = heap.pointee.kmallocOrNil(Arch.TrapFrame.self) else {
                    destroyPartialAddressSpace(&addressSpace)
                    throw .heapAllocationFailed
                }

                trapFramePtr.initialize(to: Arch.TrapFrame())
                trapFramePtr.pointee.elr   = elf.entryPoint
                trapFramePtr.pointee.spsr  = 0x0
                trapFramePtr.pointee.spel0 = userStackTop

                let pid = self.pidCounter
                self.pidCounter += 1

                let identity = self.identityCounter
                self.identityCounter += 1

                guard let kStackRaw = heap.pointee.kmallocOrNil(4096) else {
                    heap.pointee.kfree(trapFramePtr)
                    destroyPartialAddressSpace(&addressSpace)
                    throw .heapAllocationFailed
                }

                let kStackTop = kStackRaw.advanced(by: 4096)
                let initialBreak = (elf.loadEnd + UserSpaceLayout.pageSize - 1) & ~(UserSpaceLayout.pageSize - 1)

                guard let metadataPtr = heap.pointee.kmallocOrNil(ProcessMetadata.self) else {
                    heap.pointee.kfree(kStackRaw)
                    heap.pointee.kfree(trapFramePtr)
                    destroyPartialAddressSpace(&addressSpace)
                    throw .heapAllocationFailed
                }

                metadataPtr.initialize(to: ProcessMetadata(
                    elfImage: elf.image, elfLoadBase: elf.loadBase,
                    elfLoadEnd: elf.loadEnd, programBreak: initialBreak
                ))

                // The `Process` is the last block on purpose: it is the only one
                // any other container can name, and it is still unknown to the
                // scheduler, to every endpoint queue and to every family list, so
                // freeing the partial set here can corrupt nothing.
                guard let processPtr = heap.pointee.kmallocOrNil(Process.self) else {
                    heap.pointee.kfree(metadataPtr)
                    heap.pointee.kfree(kStackRaw)
                    heap.pointee.kfree(trapFramePtr)
                    destroyPartialAddressSpace(&addressSpace)
                    throw .heapAllocationFailed
                }

                processPtr.initialize(to: Process(
                    pid: pid, identity: identity, addressSpace: addressSpace,
                    context: trapFramePtr, kernelStackTop: kStackTop,
                    kernelStackRaw: kStackRaw, metadata: metadataPtr
                ))

                vmaManagerPtr.pointee.setInitialBreak(initialBreak)
                return processPtr


            case .failure(_):
                throw .elfParsingFailed(.invalidMagicNumber)
        }
    }
    
    
    public mutating func spawnProcess() throws(ProcessManagerError) -> UnsafeMutablePointer<Process> {
        
        var addressSpace: AddressSpace
        do {
            addressSpace = try vmm.pointee.createAddressSpace()
        } catch { throw .creationProcessFailed(error) }
        
        
        guard attachVMAManager(to: &addressSpace) != nil else {
            destroyPartialAddressSpace(&addressSpace)
            throw .heapAllocationFailed
        }

        guard let trapFramePtr = heap.pointee.kmallocOrNil(Arch.TrapFrame.self) else {
            destroyPartialAddressSpace(&addressSpace)
            throw .heapAllocationFailed
        }

        trapFramePtr.initialize(to: Arch.TrapFrame())
        trapFramePtr.pointee.elr   = 0
        trapFramePtr.pointee.spsr  = 0x0
        trapFramePtr.pointee.spel0 = UserSpaceLayout.stackTop

        let pid = self.pidCounter
        self.pidCounter += 1

        let identity = self.identityCounter
        self.identityCounter += 1

        guard let kStackRaw = heap.pointee.kmallocOrNil(4096) else {
            heap.pointee.kfree(trapFramePtr)
            destroyPartialAddressSpace(&addressSpace)
            throw .heapAllocationFailed
        }

        let kStackTop = kStackRaw.advanced(by: 4096)

        guard let metadataPtr = heap.pointee.kmallocOrNil(ProcessMetadata.self) else {
            heap.pointee.kfree(kStackRaw)
            heap.pointee.kfree(trapFramePtr)
            destroyPartialAddressSpace(&addressSpace)
            throw .heapAllocationFailed
        }

        metadataPtr.initialize(to: ProcessMetadata())

        guard let processPtr = heap.pointee.kmallocOrNil(Process.self) else {
            heap.pointee.kfree(metadataPtr)
            heap.pointee.kfree(kStackRaw)
            heap.pointee.kfree(trapFramePtr)
            destroyPartialAddressSpace(&addressSpace)
            throw .heapAllocationFailed
        }

        processPtr.initialize(to: Process(
            pid           : pid,
            identity      : identity,
            addressSpace  : addressSpace,
            
            context       : trapFramePtr,
            kernelStackTop: kStackTop,
            kernelStackRaw: kStackRaw,
            
            metadata      : metadataPtr,
        ))
        
        return processPtr
    }
    
    
    public func releaseAddressSpace(_ process: UnsafeMutablePointer<Process>) throws(PPMError) {
        
        if let vmaManager = process.pointee.addressSpace.vmaManager {
            vmaManager.pointee.teardown()

            heap.pointee.kfree(vmaManager)
            process.pointee.addressSpace.vmaManager = nil
        }
        
        if let metadata = process.pointee.metadata {
            metadata.pointee.elfImage    = nil
            metadata.pointee.elfLoadBase = 0
            metadata.pointee.elfLoadEnd  = 0
        }
        
        if let trapFrame = process.pointee.context {
            heap.pointee.kfree(trapFrame)
            process.pointee.context = nil
        }

        if let stackAddress = process.pointee.kernelStackRaw {
            heap.pointee.kfree(stackAddress)
            process.pointee.kernelStackRaw = nil
            process.pointee.kernelStackTop = nil
        }
        
        defer { reinstallCurrentAddressSpace() }

        try vmm.pointee.destroyAddressSpace(
            addressSpace: process.pointee.addressSpace
        )
    }


    /// Put the running process's root back in TTBR0 after another address
    /// space has been torn down.
    ///
    /// `destroyAddressSpace` has to detach the root it is about to free, and it
    /// does so by installing the kernel identity root. That is right when the
    /// caller is dying' then`killCurrent` clears the current process first, and the
    /// scheduler installs whoever runs next, but every other caller is a live
    /// process destroying *somebody else's* space: a parent in `terminate`, or a
    /// failed `spawn`/`split` unwinding its half-built child. Those return
    /// straight to EL0, and the identity root carries no user mapping at all, so
    /// the caller would fault on its own next instruction, fault again servicing
    /// it into a root that is not installed, and never make progress.
    ///
    /// A nil current process is therefore the signal to leave TTBR0 alone; it is
    /// the only case where the outgoing root was the running one.
    @inline(__always)
    private func reinstallCurrentAddressSpace() {
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
    public func releaseProcess(_ process: UnsafeMutablePointer<Process>) {
        
        if let parent = process.pointee.family.parent {
            parent.pointee.family.removeChild(process)

            if let parentMeta = parent.pointee.metadata,
               parentMeta.pointee.waitingChildPid == process.pointee.pid {

                parentMeta.pointee.waitingChildPid = nil
            }
        }

        if let metadata = process.pointee.metadata {
            heap.pointee.kfree(metadata)
            process.pointee.metadata = nil
        }

        heap.pointee.kfree(process)
    }


    /// Decodes the status a parent observes when it reaps this corpse.
    ///
    /// `exitReason` is the only field that records how a process died. The
    /// dying process's `x0` carries the code on the `exit(code)` route alone;
    /// on a fault or a `terminate` it is whatever user register happened to be
    /// live, so reading it as a status is reading noise. Both reaps — the
    /// synchronous one, where the child is already a zombie, and the
    /// asynchronous one, where the parent blocks first and the child dies
    /// later — go through this single decoder, so one death can never be
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
            Arch.CPU.setCurrentProcess(0)
            killProcess(oldProcess, reason: reason, context: context)
        }

        if let trapFrame = context.scheduler.pointee.yield() {
            if let next = Arch.CPU.getCurrentProcess() {
                
                Arch.MMU.switchUserAddressSpace(
                    next.pointee.addressSpace.rootTablePhysical,
                    asid: next.pointee.addressSpace.asid
                )
            }
            
            frame.pointee = trapFrame.pointee
            
        } else {
            Arch.CPU.setCurrentProcess(0)
            Arch.CPU.idleLoop()
        }
    }
    
    /// Tears a process down and disposes of its corpse.
    ///
    /// Returns `true` while the corpse is still reachable — parked on the
    /// scheduler's `terminated` list — so a caller that wants it may reap and
    /// release it. Returns `false` when it went to a parent already blocked in
    /// `reapChild`: that hand-off frees the `Process` block, so `process` is
    /// dangling on return and must not be touched again.
    @discardableResult
    public func killProcess(
        _ process: UnsafeMutablePointer<Process>,
          reason : ExitReason,
          context: SyscallContext
    ) -> Bool {

        let status = process.pointee.status

        guard case .terminated = status else {

            releaseOrphanedZombies(of: process, context)

            let adopter = initProcess.flatMap { candidate -> UnsafeMutablePointer<Process>? in
                if case .terminated = candidate.pointee.status { return nil }
                return candidate
            }

            let newParent = process.pointee.family.parent ?? adopter

            if let newParent, newParent != process {
                process.pointee.family.reparent(newParent: newParent)

            } else { process.pointee.family.orphanChildren() }

            switch status {
                case .blockedOnSend(let ep?), .blockedOnReceive(let ep?):
                    ep.pointee.queue.remove(element: process)
                    if ep.pointee.queue.isEmpty() { ep.pointee.state = .idle }
                    
                case .ready, .waiting:
                    context.scheduler.pointee.unlink(process, in: status)
                    
                default: break
            }
                        
            severReplyLinks(of: process, context)
            context.ipc.pointee.releaseCapabilities(of: process)
            
            process.pointee.status                       = .terminated
            process.pointee.metadata?.pointee.exitReason = reason

            try? context.processManager.pointee.releaseAddressSpace(process)

            return deliverCorpse(process, context)
        }

        // Already a zombie: somebody else ran the teardown and left the corpse
        // on the `terminated` list, so it is still there to be reaped.
        return true
    }

    /// Hands a fresh corpse to whoever is entitled to it.
    ///
    /// Every death route ends here — `exit`, a fault, `terminate`, a `split`
    /// unwinding its half-built child — because the two outcomes are exclusive
    /// and a route that performed neither was doubly broken: the parent parked
    /// in `reapChild` was never woken, and the unrecorded `Process` block was
    /// left unreachable by any later reap.
    ///
    /// `releaseProcess` has to run before `wakeUp`, since it is what clears the
    /// parent's `waitingChildPid`. A parent resumed while still claiming to
    /// wait on a pid whose `Process` is gone would carry that claim into its
    /// next death or reap and walk a freed block.
    private func deliverCorpse(
        _ process: UnsafeMutablePointer<Process>,
        _ context: SyscallContext
    ) -> Bool {

        guard let parent     = process.pointee.family.parent,
              let parentMeta = parent.pointee.metadata,
              parentMeta.pointee.waitingChildPid == process.pointee.pid
        else {
            context.scheduler.pointee.addZombie(process)
            return true
        }

        // Read the status before `releaseProcess` frees the metadata block it
        // lives in.
        parent.pointee.context?.pointee.x0 = Self.exitStatus(of: process)

        releaseProcess(process)
        try? context.scheduler.pointee.wakeUp(parent.pointee.pid)

        return false
    }

    private func severReplyLinks(
        of process: UnsafeMutablePointer<Process>,
        _  context: SyscallContext
    ) {

        if let waiter = process.pointee.replyTo {
            process.pointee.replyTo = nil

            if waiter.pointee.replyPartner == process {
                waiter.pointee.replyPartner = nil
            }

            waiter.pointee.context?.pointee.x0 = IPCStatus.peerDied.rawValue
            context.scheduler.pointee.resume(waiter)
        }

        if let server = process.pointee.replyPartner {
            process.pointee.replyPartner = nil

            if server.pointee.replyTo == process {
                server.pointee.replyTo = nil
            }
        }
    }

    /// Frees the children that already died and can no longer be named.
    ///
    /// A zombie is only reachable through `family.findChild(id:)`, so once its
    /// parent is gone nobody knows its pid: reparenting it to the grandparent
    /// would keep it in the scheduler's `terminated` list and leak its
    /// `Process` plus `ProcessMetadata` for the rest of the boot. Its address
    /// space is already down (`killProcess` did that when it became a zombie),
    /// so all that is left is to unlink it from `terminated` and free it.
    /// Which must happen in that order, and only for a zombie the list really
    /// holds, because `LinkedList.remove` on a node it does not own would
    /// clear the head and drop every other zombie.
    private func releaseOrphanedZombies(
        of process: UnsafeMutablePointer<Process>,
        _  context: SyscallContext
    ) {
        var current = process.pointee.family.firstChild

        while let child = current {
            current = child.pointee.family.nextSibling

            guard case .terminated = child.pointee.status,
                  context.scheduler.pointee.search(
                    in: .terminated,
                    to: child.pointee.pid
                  ) == child
            else { continue }

            guard context.scheduler.pointee.reapChild(child) else { continue }

            releaseProcess(child)
        }
    }

    private func attachVMAManager(
        to addressSpace: inout AddressSpace
    ) -> UnsafeMutablePointer<VMAManager>? {

        guard let vmaPtr = heap.pointee.kmallocOrNil(VMAManager.self) else {
            return nil
        }

        vmaPtr.initialize(to: VMAManager(
            heap             : heap,
            vmm              : vmm,
            ppm              : ppm,
            rootTablePhysical: addressSpace.rootTablePhysical,
            asid             : addressSpace.asid
        ))

        addressSpace.vmaManager = vmaPtr
        return vmaPtr
    }
    
    private func destroyPartialAddressSpace(_ space: inout AddressSpace) {
        
        if let vma = space.vmaManager {
            vma.pointee.teardown()
            heap.pointee.kfree(vma)
            
            space.vmaManager = nil
        }
        
        try? vmm.pointee.destroyAddressSpace(addressSpace: space)

        reinstallCurrentAddressSpace()
    }
}
