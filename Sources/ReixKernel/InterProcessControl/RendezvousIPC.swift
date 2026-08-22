//
//  RendezvousIPC.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


import ReixABI

public struct RendezvousIPC: IPCInterface, Loggable {
    
    public static var errorMessageAllocation: StaticString = "Failed to allocate IPC on the kernel heap"
    
    public static let nameLog : StaticString = "[IPC ]"
    public static let logLevel: LogLevel     = .info
    
    var endpoints: InlineArray<64, UnsafeMutablePointer<Endpoint>?>
    var ppm      : UnsafeMutablePointer<KernelPPM>
    var scheduler: UnsafeMutablePointer<KernelScheduler>
    var heap     : UnsafeMutablePointer<KernelHeap>

    init(
        ppm      : UnsafeMutablePointer<KernelPPM>,
        scheduler: UnsafeMutablePointer<KernelScheduler>,
        heap     : UnsafeMutablePointer<KernelHeap>
    ) {
        self.endpoints = InlineArray(repeating: nil)
        self.ppm       = ppm
        self.scheduler = scheduler
        self.heap      = heap

        Self.boot("IPC ready.")
    }
    
    
    public mutating func send(
        capability: Capability,
        frame     : AArch64.TrapFrame,
        blocking  : Bool = true
        
    ) -> Result<CommunicationMessageResult, IPCError> {
        
        guard capability.rights.contains(.send) else {
            return .failure(.notEnoughRights)
        }
        
        guard case .endpoint(let ep) = capability.target else {
            return .failure(.invalidCapability)
        }
        
        let endpointPtr = ep
        let grantWord   = frame.x6
        let grantHandle = UInt32(truncatingIfNeeded: grantWord)
        let grantRights = CapRights(rawValue: UInt8(truncatingIfNeeded: grantWord >> 32))

        guard let currentProcess = Arch.CPU.getCurrentProcess() else {
            return .failure(.noReply)
        }

        if endpointPtr.pointee.state == .recvBlocked {

            guard let receiverProcess = endpointPtr.pointee.queue.popFront() else {
                return .failure(.noReply)
            }

            guard let receiverContext = receiverProcess.pointee.context else {
                return .failure(.noReply)
            }


            var transferResult: Result<UInt32, IPCError>?
            if grantHandle != UInt32.max {

                transferResult = transferCapability(
                    from   : currentProcess,
                    handler: grantHandle,
                    to     : receiverProcess,
                    rights : grantRights
                )
            }

            var grantRejected = false
            switch transferResult {
                case .success(let newGrantHandle):
                    receiverContext.pointee.x7 = UInt64(newGrantHandle)

                case .failure(_):
                    receiverContext.pointee.x7 = UInt64(UInt32.max)
                    grantRejected = true

                case nil:
                    receiverContext.pointee.x7 = UInt64(UInt32.max)
            }


            if endpointPtr.pointee.queue.isEmpty() {
                endpointPtr.pointee.state = .idle
            }

            let measuring = pmuRecording(TracePMU.self)
            let cycles0   = measuring ? Arch.PMU.cycles()       : 0
            let instr0    = measuring ? Arch.PMU.instructions() : 0

            Message(from: frame).write(to: receiverContext)

            traceTransfer(from: currentProcess, to: receiverProcess)

            receiverContext.pointee.x6 = ipcTag(
                from   : currentProcess,
                session: capability.badge
            )

            disarmDeadline(on: receiverProcess)

            wake(receiverProcess)

            if measuring {
                let instr1 = Arch.PMU.instructions()
                let instrDelta = UInt32(truncatingIfNeeded: instr1)
                    &- UInt32(truncatingIfNeeded: instr0)

                Trace.emit(
                    TracePMU.self,
                    code: TraceCode.pmuSection,
                    info: PMUSectionID.ipcTransfer,
                    a   : Arch.PMU.cycles() &- cycles0,
                    b   : UInt64(instrDelta)
                )
            }

            return .success(.sended(grantRejected: grantRejected))
        }

        guard blocking else { return .failure(.wouldBlock) }


        currentProcess.pointee.pending = PendingMessage(
            message     : Message(from: frame),
            session     : capability.badge,
            grant       : grantHandle == UInt32.max ? nil : grantHandle,
            rights      : grantRights,
            expectsReply: false
        )

        disarmDeadline(on: currentProcess)

        endpointPtr.pointee.queue.pushBack(currentProcess)

        endpointPtr.pointee.state     = .sendBlocked
        currentProcess.pointee.status = .blockedOnSend(endpointPtr)

        traceBlock(TraceBlockReason.sendQueue, on: endpointPtr)

        return .success(.blocked)

    }
    
    
    public mutating func receive(
        capability  : Capability,
        frame       : UnsafeMutablePointer<AArch64.TrapFrame>,
        blocking    : Bool = true,
        timeoutTicks: UInt64? = nil
        
    ) -> Result<CommunicationMessageResult, IPCError> {
        
        guard capability.rights.contains(.receive) else {
            return .failure(.notEnoughRights)
        }
        
        guard case .endpoint(let ep) = capability.target else {
            return .failure(.invalidCapability)
        }
        let endpointPtr = ep

        guard let currentProcess = Arch.CPU.getCurrentProcess() else {
            return .failure(.noReply)
        }

        if endpointPtr.pointee.state == .sendBlocked {

            guard let senderProcess = endpointPtr.pointee.queue.popFront() else {
                return .failure(.noReply)
            }


            let pending = senderProcess.pointee.takePending()

            var transferResult: Result<UInt32, IPCError>? = nil
            if let pending, let grant = pending.grant {
                transferResult = transferCapability(
                    from   : senderProcess,
                    handler: grant,
                    to     : currentProcess,
                    rights : pending.rights
                )
            }

            var grantRejected = false
            switch transferResult {
                case .success(let newGrantHandle):
                    frame.pointee.x7 = UInt64(newGrantHandle)

                case .failure(_):
                    frame.pointee.x7 = UInt64(UInt32.max)
                    grantRejected    = true

                case nil:
                    frame.pointee.x7 = UInt64(UInt32.max)
            }


            if endpointPtr.pointee.queue.isEmpty() {
                endpointPtr.pointee.state = .idle
            }

            pending?.message.write(to: frame)

            traceTransfer(from: senderProcess, to: currentProcess)

            frame.pointee.x6 = ipcTag(
                from   : senderProcess,
                session: pending?.session ?? 0
            )

            if grantRejected {
                senderProcess.pointee.context?.pointee.x0 = IPCStatus.grantRejected.rawValue
            }


            if pending?.expectsReply == true {

                displaceReplyLink(of: currentProcess, for: senderProcess)

                currentProcess.pointee.replyTo     = senderProcess
                senderProcess.pointee.replyPartner = currentProcess
                senderProcess.pointee.status       = .blockedOnReply

            } else { wake(senderProcess) }

            return .success(.sended(grantRejected: false))
        }
        
        guard blocking else { return .failure(.wouldBlock) }

        if let timeoutTicks {
            guard timeoutTicks <= UInt64(Int64.max),
                  armDeadline(
                    on: currentProcess,
                    deadline: scheduler.pointee.systemTicks &+ timeoutTicks
                  ) else {
                return .failure(.timeout)
            }

        } else { disarmDeadline(on: currentProcess) }

        endpointPtr.pointee.queue.pushBack(currentProcess)
        endpointPtr.pointee.state     = .recvBlocked
        currentProcess.pointee.status = .blockedOnReceive(endpointPtr)

        traceBlock(TraceBlockReason.recvWait, on: endpointPtr)

        return .success(.blocked)
    }


    public mutating func call(
        capability: Capability,
        frame     : AArch64.TrapFrame
    ) -> Result<CommunicationMessageResult, IPCError> {
        
        guard capability.rights.contains(.send) else {
            return .failure(.notEnoughRights)
        }
        
        guard case .endpoint(let ep) = capability.target else {
            return .failure(.invalidCapability)
        }
        let endpointPtr = ep

        guard let currentProcess = Arch.CPU.getCurrentProcess() else {
            return .failure(.noReply)
        }

        if endpointPtr.pointee.state == .recvBlocked {
            guard let receiverProcess = endpointPtr.pointee.queue.popFront() else {
                return .failure(.noReply)
            }

            // A queued process is always a live IPC participant; a broken
            // invariant is the only way this is nil.
            guard let receiverContext = receiverProcess.pointee.context else {
                return .failure(.noReply)
            }

            if endpointPtr.pointee.queue.isEmpty() {
                endpointPtr.pointee.state = .idle
            }

            Message(from: frame).write(to: receiverContext)

            traceTransfer(from: currentProcess, to: receiverProcess)

            receiverContext.pointee.x6 = ipcTag(
                from   : currentProcess,
                session: capability.badge
            )

            receiverContext.pointee.x7 = UInt64(UInt32.max)

            disarmDeadline(on: receiverProcess)

            displaceReplyLink(of: receiverProcess, for: currentProcess)

            receiverProcess.pointee.replyTo     = currentProcess
            currentProcess.pointee.replyPartner = receiverProcess

            currentProcess.pointee.status = .blockedOnReply

            traceBlock(TraceBlockReason.call, on: endpointPtr)

            wake(receiverProcess)

            return .success(.blocked)
        }
        
        
        // Server not ready

        currentProcess.pointee.pending = PendingMessage(
            message     : Message(from: frame),
            session     : capability.badge,
            grant       : nil,
            rights      : [],
            expectsReply: true
        )

        currentProcess.pointee.status = .blockedOnSend(endpointPtr)

        disarmDeadline(on: currentProcess)

        endpointPtr.pointee.queue.pushBack(currentProcess)
        endpointPtr.pointee.state = .sendBlocked

        traceBlock(TraceBlockReason.call, on: endpointPtr)

        return .success(.blocked)
    }
    
    
    public mutating func reply(
        frame: AArch64.TrapFrame
    ) -> Result<CommunicationMessageResult, IPCError> {
        let grantWord = frame.x6
        
        return replyInternal(
            frame      : frame,
            grantHandle: UInt32(truncatingIfNeeded: grantWord),
            grantRights: CapRights(rawValue: UInt8(truncatingIfNeeded: grantWord >> 32))
        )
    }
    
    public mutating func replyRecv(
        capability: Capability,
        frame     : UnsafeMutablePointer<AArch64.TrapFrame>
    ) -> Result<CommunicationMessageResult, IPCError> {
        guard capability.rights.contains(.receive) else { return .failure(.notEnoughRights) }

        _ = replyInternal(
            frame      : frame.pointee,
            grantHandle: UInt32.max,
            grantRights: []
        )
        
        return receive(capability: capability, frame: frame)
    }
    
    
    @inline(__always)
    private mutating func replyInternal(
        frame      : AArch64.TrapFrame,
        grantHandle: UInt32,
        grantRights: CapRights
    ) -> Result<CommunicationMessageResult, IPCError> {
        
        guard let currentProcess = Arch.CPU.getCurrentProcess(),
              let replyProcess = currentProcess.pointee.replyTo else {

            return .failure(.noReply)
        }

        guard let replyContext = replyProcess.pointee.context else {
            return .failure(.noReply)
        }

        Message(from: frame).write(to: replyContext)

        traceTransfer(from: currentProcess, to: replyProcess)

        replyContext.pointee.x6 = ipcTag(
            from   : currentProcess,
            session: 0
        )

        var transferResult: Result<UInt32, IPCError>? = nil
        if grantHandle != UInt32.max {
            transferResult = transferCapability(
                from   : currentProcess,
                handler: grantHandle,
                to     : replyProcess,
                rights : grantRights
            )
        }

        var grantRejected = false
        switch transferResult {
            case .success(let newHandle):
                replyContext.pointee.x7 = UInt64(newHandle)

            case .failure(_):
                replyContext.pointee.x7 = UInt64(UInt32.max)
                grantRejected = true

            case nil:
                replyContext.pointee.x7 = UInt64(UInt32.max)
        }

        wake(replyProcess)
        currentProcess.pointee.replyTo    = nil
        replyProcess.pointee.replyPartner = nil

        return .success(.sended(grantRejected: grantRejected))
    }
    
    
    public mutating func spawnEndpoint(
        for process: UnsafeMutablePointer<Process>,
            rights : CapRights = [.send, .receive, .grant, .derive],
            owner  : PID?      = nil
    ) -> Result<UInt32, IPCError> {
        
        var endpointID: Int? = nil
        for i in 0..<endpoints.count {
            
            if endpoints[i] == nil {
                endpointID = i
                break
            }
        }
        
        guard let id = endpointID else {
            return .failure(.notFoundFreeEndpoint)
        }
    
        guard let endpoint = heap.pointee.kmallocOrNil(Endpoint.self) else {
            return .failure(.outOfEndpoints)
        }

        endpoint.initialize(
            to: Endpoint(queue: LinkedList(head: nil, tail: nil))
        )

        endpoints[id] = endpoint

        let capability = Capability(
            target: .endpoint(endpoint),
            badge : Badge(0),
            rights: rights
        )

        guard let handle = process.pointee.metadata.pointee.capsTable.install(capability) else {
            endpoints[id] = nil
            heap.pointee.kfree(endpoint)

            return .failure(.outOfEndpoints)
        }

        retain(capability)

        return .success(handle)
    }
    
    
    public mutating func spawnEndpoint(
        for parent: UnsafeMutablePointer<Process>,
        and child : UnsafeMutablePointer<Process>
    ) -> Result<UInt32, IPCError> {
        
        var endpointID: Int? = nil
        for i in 0..<endpoints.count {
            
            if endpoints[i] == nil {
                endpointID = i
                break
            }
        }
        
        guard let id = endpointID else {
            return .failure(.notFoundFreeEndpoint)
        }
    
        guard let endpoint = heap.pointee.kmallocOrNil(Endpoint.self) else {
            return .failure(.outOfEndpoints)
        }

        endpoint.initialize(
            to: Endpoint(queue: LinkedList(head: nil, tail: nil))
        )

        endpoints[id] = endpoint

        let parentCapability = Capability(
            target: .endpoint(endpoint),
            badge : Badge(0),
            rights: [.send, .receive, .grant]
        )

        guard let parentEndpointHandle = parent.pointee.metadata.pointee.capsTable.install(parentCapability) else {
            endpoints[id] = nil
            heap.pointee.kfree(endpoint)

            return .failure(.outOfEndpoints)
        }
        
        retain(parentCapability)

        let childCapability = Capability(
            target: .endpoint(endpoint),
            badge : Badge(0),
            rights: [.send, .receive]
        )
        guard let childEndpointHandle = child.pointee.metadata.pointee.capsTable.install(childCapability) else {
            _ = parent.pointee.metadata.pointee.capsTable.remove(parentCapability)

            release(parentCapability)
            return .failure(.outOfEndpoints)
        }
        
        retain(childCapability)
        
        child.pointee.metadata.pointee.parentEndpoint = childEndpointHandle

        return .success(parentEndpointHandle)
    }
    
    public mutating func createShared(
        for process  : UnsafeMutablePointer<Process>,
            page     : consuming PhysicalPage,
            pageCount: UInt32,
            forDevice: Bool = false
    ) -> Result<(
        handle: UInt32,
        region: UnsafeMutablePointer<SharedRegion>
    ), IPCError> {
    
        guard let sharedRegion = heap.pointee.kmallocOrNil(SharedRegion.self) else {
            try? ppm.pointee.free(page)

            return .failure(.outOfEndpoints)
        }

        sharedRegion.initialize(
            to: SharedRegion(
                physicalPage: page,
                references  : 0,
                pageCount   : pageCount
            )
        )
        
        let capability = Capability(
            target: forDevice ? .dma(sharedRegion) : .shared(sharedRegion),
            badge : Badge(0),
            rights: [.send, .receive, .grant, .read, .write]
        )

        guard let handle = process.pointee.metadata.pointee.capsTable.install(capability) else {
            if let failure = sharedRegion.move().releaseFrame(ppm: ppm) {
                Self.error("shared region unwound with no capability installed but its frame was refused, \(failure.description)")
            }

            heap.pointee.kfree(UnsafeMutableRawPointer(sharedRegion))

            return .failure(.outOfEndpoints)
        }
        
        retain(capability)

        return .success((handle, sharedRegion))
    }
    
    public mutating func transferCapability(
        from senderProcess  : UnsafeMutablePointer<Process>,
             handler        : UInt32,
        to   receiverProcess: UnsafeMutablePointer<Process>,
             rights         : CapRights
        
    ) -> Result<UInt32, IPCError> {
        // A nil metadata means the process is not a live IPC participant;
        // fail the same way an unresolvable capability handle does.
        guard let senderMetadata = senderProcess.pointee.metadata else {
            return .failure(.invalidCapability)
        }

        guard let capability = senderMetadata.pointee.capsTable.resolve(handler) else {
            return .failure(.invalidCapability)
        }

        guard capability.rights.contains(.grant) else {
            return .failure(.notEnoughRights)
        }

        let effective = Self.attenuatedRights(source: capability.rights, requested: rights)
        let receiverCap = Capability(
            target: capability.target,
            badge : capability.badge,
            rights: effective
        )

        guard let receiverMetadata = receiverProcess.pointee.metadata else {
            return .failure(.invalidCapability)
        }

        guard let receiverHandle = receiverMetadata.pointee.capsTable.install(receiverCap) else {
            return .failure(.outOfEndpoints)
        }

        retain(receiverCap)

        return .success(receiverHandle)
    }


    @discardableResult
    public mutating func injectCapability(
        from parent: UnsafeMutablePointer<Process>,
             handle: UInt32,
        to   child : UnsafeMutablePointer<Process>,
             slot  : UInt32,
             rights: CapRights
    ) -> Bool {
        guard let capability = parent.pointee.metadata.pointee.capsTable.resolve(handle),
              capability.rights.contains(.grant) else {
            return false
        }

        guard child.pointee.metadata.pointee.parentEndpoint != slot else {
            return false
        }

        let effective = Self.attenuatedRights(source: capability.rights, requested: rights)
        let childCap  = Capability(
            target: capability.target,
            badge : capability.badge,
            rights: effective
        )

        let (installed, displaced) = child.pointee.metadata.pointee.capsTable.install(
            at: slot,
            childCap
        )
        guard installed else { return false }

        retain(childCap)

        if let displaced { release(displaced) }

        return true
    }

    static func attenuatedRights(source: CapRights, requested: CapRights) -> CapRights {
        requested.intersection(source)
    }


    @inline(__always)
    public func hasDeadlineDue(at now: UInt64) -> Bool {
        KernelDeadlineQueue.shared.hasDue(at: now)
    }

    public mutating func checkTimeouts(now: UInt64) {
        guard hasDeadlineDue(at: now) else { return }

        KernelDeadlineQueue.shared.poll(
            now   : now,
            budget: KernelDeadlineQueue.tickBudget
        ) { process, kind in
            
            switch kind {
                case .ipc  : expireIPCWait(process)
                case .sleep: SleepSyscall.expire(process)
                case .none : break
            }
        }
    }

    
    // MARK: - Trace funnels

    /// Puts `process` back on the ready queue, and records that it happened.
    ///
    /// Every resume in this file goes through here, the rendezvous fast paths,
    /// the reply, the timeout scan and the displaced caller alike, so the trace
    /// sees one `ipcWake` per unparked process wherever the wake came from and
    /// a new wake site cannot quietly skip it.
    ///
    /// Not `mutating`: the scheduler is reached through a pointer, which is
    /// what lets `displaceReplyLink` call this too.
    @inline(__always)
    private func wake(_ process: UnsafeMutablePointer<Process>) {
        Trace.emit(
            TraceIPC.self,
            code: TraceCode.ipcWake,
            a   : process.pointee.pid
        )

        scheduler.pointee.resume(process)
    }


    /// Records that the running process parked on `endpoint`.
    ///
    /// The endpoint is identified by its address rather than by its index in
    /// `endpoints`: the index would cost a scan of all 64 slots on a path that
    /// is supposed to be almost free, and an address is just as unique for as
    /// long as the endpoint lives, which is as long as anything can be waiting
    /// on it.
    @inline(__always)
    private func traceBlock(
        _  reason  : UInt16,
        on endpoint: UnsafeMutablePointer<Endpoint>
    ) {
        Trace.emit(
            TraceIPC.self,
            code: TraceCode.ipcBlock,
            info: reason,
            a   : UInt64(UInt(bitPattern: endpoint))
        )
    }


    /// Records a message actually crossing, which is the event the four
    /// rendezvous fast paths have in common and the only one that says work
    /// moved rather than merely that somebody waited.
    @inline(__always)
    private func traceTransfer(
        from sender  : UnsafeMutablePointer<Process>,
        to   receiver: UnsafeMutablePointer<Process>
    ) {
        Trace.emit(
            TraceIPC.self,
            code: TraceCode.ipcTransfer,
            a   : sender.pointee.pid,
            b   : receiver.pointee.pid
        )
    }


    /// Whether the one PMU-bracketed section should read the counters at all.
    ///
    /// Generic on the category for `Trace.syscallSpan`'s reason: with
    /// `C.isEnabled` false this is the constant `false`, both stamp ternaries at
    /// the call site collapse to zero, the emit becomes dead code and a class
    /// compiled out leaves nothing whatsoever on the transfer path. Left on and
    /// merely masked, it costs one mask test and one flag load.
    ///
    /// `Arch.PMU.initialized` belongs in the same answer rather than in a guard
    /// of its own: counters that were never enabled read as plausible numbers
    /// and not as an error, so a section taken before boot armed them would be
    /// filed as a real measurement of nothing.
    @inline(__always)
    private func pmuRecording<C: TraceCategory>(_ category: C.Type) -> Bool {
        C.isEnabled && Trace.runtimeMask & C.bit != 0 && Arch.PMU.initialized
    }


    // MARK: - Helpers

    @inline(__always)
    private mutating func armDeadline(
        on process : UnsafeMutablePointer<Process>,
           deadline: UInt64
    ) -> Bool {
        KernelDeadlineQueue.shared.arm(
            process,
            kind    : .ipc,
            deadline: deadline
        )
    }

    @inline(__always)
    private mutating func disarmDeadline(on process: UnsafeMutablePointer<Process>) {
        guard process.pointee.kernelDeadlineKind == .ipc else { return }
        KernelDeadlineQueue.shared.cancel(process)
    }

    private func expireIPCWait(_ process: UnsafeMutablePointer<Process>) {
        guard case .blockedOnReceive(let endpoint) = process.pointee.status else {
            return
        }

        process.pointee.context?.pointee.x0 = IPCStatus.timeout.rawValue
        wake(process)

        if let endpoint, endpoint.pointee.queue.isEmpty() {
            endpoint.pointee.state = .idle
        }
    }

    @inline(__always)
    private func ipcTag(
        from sender: UnsafeMutablePointer<Process>,
        session    : Badge
    ) -> UInt64 {
        (UInt64(sender.pointee.identity) << 32) | UInt64(session)
    }


    /// Break the reply link `server` still holds toward an earlier caller, now
    /// that `newPeer` is taking its place.
    ///
    /// The abandoned caller is `.blockedOnReply` on a reply that can never
    /// arrive, so it is resumed with `.noReply` rather than `.peerDied`: the
    /// server and its endpoint are still alive and usable, it merely dropped
    /// this call, and telling the client its peer died would make it tear down a
    /// connection that still works.
    @inline(__always)
    private func displaceReplyLink(
        of  server : UnsafeMutablePointer<Process>,
        for newPeer: UnsafeMutablePointer<Process>
    ) {
        guard let abandoned = server.pointee.replyTo,
              abandoned != newPeer else { return }

        abandoned.pointee.replyPartner        = nil
        abandoned.pointee.context?.pointee.x0 = IPCStatus.noReply.rawValue

        wake(abandoned)
        server.pointee.replyTo = nil
    }


    @inline(__always)
    mutating func retain(_ cap: Capability) {

        switch cap.target {
            case .endpoint(let endpointPtr)    : rxRetain(endpointPtr)
            case .shared  (let sharedMemoryPtr): rxRetain(sharedMemoryPtr)
            case .dma     (let dmaRegionPtr)   : rxRetain(dmaRegionPtr)
            case .interrupt(let setPtr)        : rxRetain(setPtr)
            
            default: break // Targets without reference-counted backing.
        }
    }


    private mutating func release(_ cap: Capability) {

        switch cap.target {
            case .endpoint(let endpointPtr):
                guard rxRelease(endpointPtr) else { return }

                for i in 0..<endpoints.count where endpoints[i] == endpointPtr {
                    endpoints[i] = nil
                    break
                }

                heap.pointee.kfree(endpointPtr)

            case .shared(let sharedMemoryPtr):
                if let failure = releaseSharedRegion(
                    sharedMemoryPtr,
                    ppm : ppm,
                    heap: heap
                ) {
                    Self.error("last capability to a shared region dropped but its frame was refused, \(failure.description)")
                }

            case .dma(let dmaRegionPtr):
               
                if let failure = releaseSharedRegion(
                    dmaRegionPtr,
                    ppm : ppm,
                    heap: heap
                ) {
                    Self.error("last capability to a DMA region dropped but its frame was refused, \(failure.description)")
                }

            case .interrupt(let setPtr):
                guard rxRelease(setPtr) else { return }

                for index in 0..<Int(setPtr.pointee.lineCount) {
                    Kernel.gic.pointee.disableInterrupt(id: setPtr.pointee.lines[index])
                }

                InterruptClaims.releaseAll(of: setPtr)
                heap.pointee.kfree(setPtr)

            default: break // Targets without reference-counted backing.
        }
    }
    
    public mutating func releaseCapability(
        _ handle  : UInt32,
        of process: UnsafeMutablePointer<Process>
    ) -> Result<Void, IPCError> {
        
        guard let metadata   = process.pointee.metadata,
              let capability = metadata.pointee.capsTable.resolve(handle)
        else { return .failure(.invalidCapability) }

        release(capability)
        metadata.pointee.capsTable.remove(handle: Int(handle))

        return .success(())
    }

    public mutating func releaseCapabilities(of process: UnsafeMutablePointer<Process>) {
        disarmDeadline(on: process)

        guard let metadata = process.pointee.metadata else { return }
        
        for i in 0..<metadata.pointee.capsTable.caps.count where metadata.pointee.capsTable.caps[i] != nil {
            let capability = metadata.pointee.capsTable.caps[i]!

            release(capability)
            metadata.pointee.capsTable.remove(handle: i)
            
        }
    }
    
    /// Fork: the child inherits the parent's whole table, badges included.
    ///
    /// No badge fixup is needed or wanted. A badge is a session, and the child
    /// really is in the same conversations as the parent it was split from; the
    /// child's *identity* comes from its own `Process` and was assigned by
    /// `ProcessManager`, so a bulk copy of capabilities cannot leak the parent's
    /// principal into it. That is exactly what a table-wide re-stamp used to be
    /// for, and why forgetting it here was an impersonation bug.
    public mutating func cloneCapsTable(
        from parentMeta: UnsafeMutablePointer<ProcessMetadata>,
        to   childMeta : UnsafeMutablePointer<ProcessMetadata>
    ) {
        childMeta.pointee.capsTable = parentMeta.pointee.capsTable

        for i in 0..<childMeta.pointee.capsTable.caps.count {
            if let cap = childMeta.pointee.capsTable.caps[i] {
                retain(cap)
            }
        }
    }
}
