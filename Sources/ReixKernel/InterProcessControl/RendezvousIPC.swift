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
        let grantRights = CapRights(rawValue: UInt16(truncatingIfNeeded: grantWord >> 32))

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
            var handed = IPCDelivery.noGrant

            switch transferResult {
                case .success(let newGrantHandle):
                    handed = newGrantHandle

                case .failure(_):
                    grantRejected = true

                case nil:
                    break
            }


            if endpointPtr.pointee.queue.isEmpty() {
                endpointPtr.pointee.state = .idle
            }

            let measuring = pmuRecording(TracePMU.self)
            let cycles0   = measuring ? Arch.PMU.cycles()       : 0
            let instr0    = measuring ? Arch.PMU.instructions() : 0

            Message(from: frame).write(to: receiverContext)

            traceTransfer(from: currentProcess, to: receiverProcess)

            deliver(
                to     : receiverContext,
                from   : currentProcess,
                session: capability.badge,
                grant  : handed
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

        // Nobody is parked on the endpoint, so this send is about to wait for
        // somebody to arrive. Whether anybody can is worth asking first: an
        // endpoint with nobody left to receive on it is not busy, it is
        // finished, and a sender queued on one waits for the rest of the boot.
        guard canBeServed(currentProcess, on: endpointPtr) else {
            return .failure(.peerDied)
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

        // The device first, when it has already spoken. A line is masked from the
        // moment it fires until its driver acks, so a device with something to
        // say is a device that has stopped, and a queued request can wait a
        // moment longer than stalled hardware.
        //
        // Checking here and parking below is one step, and it has to be: an
        // interrupt landing between the two would set a bit nobody is going to
        // look at again and park the driver for ever. What makes it one step is
        // that an exception to EL1 masks IRQs and nothing in the syscall path
        // unmasks them - so if that ever changes, this needs a guard of its own
        // and the symptom will be a disk that stops answering once in a while.
        //
        // It cannot starve the clients either: an interrupt only arrives because
        // a request was accepted and submitted, so every notification is
        // downstream of a request that was already served.
        if let set = endpointPtr.pointee.signals, set.pointee.pending != 0 {

            // Into the live trap frame, not through `currentProcess.context`.
            // For a process in the middle of a syscall the two are the same
            // pointer, and writing an answer to a register through the field
            // rather than the frame is the kind of "same thing today" a test
            // cannot tell apart.
            Self.deliverNotification(set, into: frame)
            return .success(.sended(grantRejected: false))
        }

        if endpointPtr.pointee.state == .sendBlocked {

            guard let senderProcess = endpointPtr.pointee.queue.popFront() else {
                return .failure(.noReply)
            }


            let pending = senderProcess.pointee.takePending()

            var transferResult: Result<UInt32, IPCError>? = nil
            if let pending, let grant = pending.attachment {
                transferResult = transferCapability(
                    from   : senderProcess,
                    handler: grant,
                    to     : currentProcess,
                    rights : pending.rights
                )
            }

            var grantRejected = false
            var handed = IPCDelivery.noGrant

            switch transferResult {
                case .success(let newGrantHandle):
                    handed = newGrantHandle

                case .failure(_):
                    grantRejected = true

                case nil:
                    break
            }


            if endpointPtr.pointee.queue.isEmpty() {
                endpointPtr.pointee.state = .idle
            }

            pending?.message.write(to: frame)

            traceTransfer(from: senderProcess, to: currentProcess)

            deliver(
                to     : frame,
                from   : senderProcess,
                session: pending?.session ?? 0,
                grant  : handed
            )

            if grantRejected {
                senderProcess.pointee.context?.pointee.x0 = IPCStatus.grantRejected.rawValue
            }


            if pending?.expectsReply == true {

                pushWaiter(senderProcess, on: currentProcess)

                senderProcess.pointee.status = .blockedOnReply(currentProcess)

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

            // A call carries no capability, so the grant half says so rather than
            // being left at whatever the frame held.
            deliver(
                to     : receiverContext,
                from   : currentProcess,
                session: capability.badge
            )

            disarmDeadline(on: receiverProcess)

            pushWaiter(currentProcess, on: receiverProcess)

            currentProcess.pointee.status = .blockedOnReply(receiverProcess)

            traceBlock(TraceBlockReason.call, on: endpointPtr)

            wake(receiverProcess)

            return .success(.blocked)
        }
        
        
        // Server not ready

        // Not ready and never going to be are different answers, and this is
        // where they part. A call to a server that died earlier used to be
        // queued on an endpoint nobody can receive on, which is how one command
        // after a file system crash wedged the shell for good.
        guard canBeServed(currentProcess, on: endpointPtr) else {
            return .failure(.peerDied)
        }

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
    
    
    /// Answers a caller. `target` names which one, and nil means the newest.
    ///
    /// A server with one request in flight passes nil and never thinks about
    /// this. One holding several says which, and the name it uses is the caller's
    /// identity, which it already has: every request arrives carrying it, and
    /// every server that keeps per-client state is already keyed on it.
    public mutating func reply(
        frame : AArch64.TrapFrame,
        target: UnsafeMutablePointer<Process>? = nil
    ) -> Result<CommunicationMessageResult, IPCError> {
        let grantWord = frame.x6
        
        return replyInternal(
            frame      : frame,
            grantHandle: UInt32(truncatingIfNeeded: grantWord),
            grantRights: CapRights(rawValue: UInt16(truncatingIfNeeded: grantWord >> 32)),
            target     : target
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
        grantRights: CapRights,
        target     : UnsafeMutablePointer<Process>? = nil
    ) -> Result<CommunicationMessageResult, IPCError> {
        
        guard let currentProcess = Arch.CPU.getCurrentProcess() else {
            return .failure(.noReply)
        }

        // The named one, or the newest. A named one that is not waiting on this
        // process was already refused by whoever resolved it, so reaching here
        // with nil and no `replyTo` is a server answering a call it does not
        // have.
        guard let replyProcess = target ?? currentProcess.pointee.replyTo else {
            return .failure(.noReply)
        }

        guard let replyContext = replyProcess.pointee.context else {
            return .failure(.noReply)
        }

        Message(from: frame).write(to: replyContext)

        traceTransfer(from: currentProcess, to: replyProcess)

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
        var handed = IPCDelivery.noGrant

        switch transferResult {
            case .success(let newHandle):
                handed = newHandle

            case .failure(_):
                grantRejected = true

            case nil:
                break
        }

        // A reply belongs to no conversation of its own: the caller knows which
        // question it asked. So the session is zero and the identity is the
        // server's, which is the one thing a caller could not have known.
        deliver(
            to     : replyContext,
            from   : currentProcess,
            session: 0,
            grant  : handed
        )

        wake(replyProcess)

        Self.unlinkWaiter(replyProcess, from: currentProcess)

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
                case .irq  : IrqWaitSyscall.expire(process)
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
    /// what lets `parkReplyLink` call this too.
    /// How many of `process`'s own capabilities could receive on `endpoint`.
    ///
    /// Needed because an endpoint's receiver count includes the sender itself
    /// when the sender happens to hold one, and a process cannot answer its own
    /// blocking send. Every spawn makes exactly that shape: the endpoint between
    /// a parent and its child gives *both* sides `.receive`, so a bare count of
    /// receivers says one is left when the only one left is the sender.
    ///
    /// A scan of thirty-two slots, on the one path that was about to go to
    /// sleep for an unbounded time. It is not on the delivery path.
    private func receiversOwned(
        by process : UnsafeMutablePointer<Process>,
        on endpoint: UnsafeMutablePointer<Endpoint>
    ) -> UInt16 {

        guard let metadata = process.pointee.metadata else { return 0 }

        var mine: UInt16 = 0

        for slot in 0..<metadata.pointee.capsTable.caps.count {
            guard let cap = metadata.pointee.capsTable.caps[slot],
                  case .endpoint(let held) = cap.target,
                  held == endpoint,
                  cap.rights.contains(.receive)
            else { continue }

            mine &+= 1
        }

        return mine
    }


    /// Whether anybody other than `process` could ever take a message off
    /// `endpoint`.
    ///
    /// The question a blocking send has to have answered before it agrees to
    /// wait. `false` does not mean the endpoint is busy; it means the other half
    /// of the rendezvous does not exist, so waiting is waiting for nobody.
    @inline(__always)
    private func canBeServed(
        _  process : UnsafeMutablePointer<Process>,
        on endpoint: UnsafeMutablePointer<Endpoint>
    ) -> Bool {
        endpoint.pointee.receivers > receiversOwned(by: process, on: endpoint)
    }


    /// Lets go of everybody queued to send on `endpoint` who can no longer be
    /// served.
    ///
    /// Run whenever a capability that could receive there goes away, which in
    /// practice is when the process holding it died. A sender parked here agreed
    /// to wait for somebody to arrive, and the answer to that has just become
    /// no; the alternative is that it waits for the rest of the boot.
    ///
    /// Asked per sender rather than once for the endpoint, because "can be
    /// served" depends on who is asking: on a parent-child endpoint both sides
    /// hold `.receive`, so the same endpoint is still serviceable for one of
    /// them and finished for the other.
    ///
    /// `.peerDied` and not `.noReply`. A server that drops one request is still
    /// there and its client should keep talking to it; this is the other thing,
    /// and it is the same word `severReplyLinks` gives a request that was
    /// already in flight when its server died.
    private mutating func abandonUnservable(_ endpoint: UnsafeMutablePointer<Endpoint>) {

        guard endpoint.pointee.state == .sendBlocked else { return }

        var current = endpoint.pointee.queue.getIterator()

        while let waiting = current {
            // Read before the node is unlinked, or the walk ends here.
            current = waiting.pointee.next

            // A corpse is out of this queue before its own capabilities are
            // released, so this is belt and braces rather than a case anybody
            // has seen.
            if case .terminated = waiting.pointee.status { continue }

            if canBeServed(waiting, on: endpoint) { continue }

            endpoint.pointee.queue.remove(element: waiting)

            // The message it never got to send. Nothing will read it now, and a
            // pending message on a process queued nowhere is a lie about where
            // that process is.
            _ = waiting.pointee.takePending()

            waiting.pointee.context?.pointee.x0 = IPCStatus.peerDied.rawValue

            // `resume` would remove it from this queue too, and cannot: it is
            // already unlinked, and `LinkedList.remove` refuses a node with no
            // links and no claim on the head.
            wake(waiting)
        }

        if endpoint.pointee.queue.isEmpty() { endpoint.pointee.state = .idle }
    }


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
    /// Lays the two delivery registers into a receiver's frame.
    ///
    /// The one place that does it, and every path comes here: immediate send,
    /// queued send, receive, call, reply, and the two that carry no grant. Six
    /// copies of two shifts is six chances to get one of them wrong and one of
    /// them being the path nothing exercises.
    private func deliver(
        to context : UnsafeMutablePointer<Arch.TrapFrame>,
        from sender: UnsafeMutablePointer<Process>,
        session    : Badge,
        grant      : UInt32 = IPCDelivery.noGrant
    ) {
        context.pointee.x6 = session
        context.pointee.x7 = IPCDelivery.principal(
            sender.pointee.identity,
            grant: grant
        )
    }


    /// How many callers one server may have parked besides the newest.
    ///
    /// Eight, like every other table here, and a bound rather than a capacity:
    /// nothing is allocated per parked caller. The number only decides when a
    /// server that keeps taking requests without answering them starts losing
    /// the oldest instead of holding it for ever.
    static let deferredReplyLimit: UInt8 = 8

    /// Whether a server ever hit that bound, said once.
    nonisolated(unsafe) static var saidRepliesOverflowed = false


    /// Makes `caller` the newest of `server`'s waiting callers.
    ///
    /// The one that was newest is pushed down the list rather than broken. It
    /// used to be broken: it was `.blockedOnReply` on a reply that could never
    /// arrive, so it was resumed with `noReply`, and that single line is why
    /// nothing in this system could have two requests in flight. A server that
    /// took a second request before answering the first dropped the first.
    ///
    /// Past the bound the old behaviour comes back, on the oldest caller, with
    /// the status it always used: a caller held for ever is worse than a caller
    /// told its call was dropped. Said out loud, because a server that gets here
    /// has a bug and would otherwise keep hitting it in silence.
    @inline(__always)
    private func pushWaiter(
        _ caller : UnsafeMutablePointer<Process>,
        on server: UnsafeMutablePointer<Process>
    ) {
        guard server.pointee.replyTo != caller else { return }

        if server.pointee.deferredReplies >= Self.deferredReplyLimit {
            dropOldestWaiter(of: server)
        }

        caller.pointee.nextWaiter = server.pointee.replyTo

        if server.pointee.replyTo != nil {
            server.pointee.deferredReplies &+= 1
        }

        server.pointee.replyTo = caller
    }


    /// Lets go of the caller at the end of `server`'s list, telling it its call
    /// was dropped.
    ///
    /// `noReply` and not `peerDied`: the server and its endpoint are alive and
    /// usable, it merely dropped this call, and telling the client its peer died
    /// would make it tear down a connection that still works.
    @inline(__always)
    private func dropOldestWaiter(of server: UnsafeMutablePointer<Process>) {

        guard var previous = server.pointee.replyTo,
              var oldest   = previous.pointee.nextWaiter
        else { return }

        while let next = oldest.pointee.nextWaiter {
            previous = oldest
            oldest   = next
        }

        if !Self.saidRepliesOverflowed {
            Self.saidRepliesOverflowed = true
            kprint("[ IPC   ] a server has too many unanswered calls, dropping the oldest")
        }

        previous.pointee.nextWaiter        = nil
        oldest.pointee.nextWaiter          = nil
        oldest.pointee.context?.pointee.x0 = IPCStatus.noReply.rawValue

        // The link to this server goes with the status, which `wake` clears.
        wake(oldest)

        server.pointee.deferredReplies &-= 1
    }


    /// The caller with `identity` waiting on `server`, or nil.
    ///
    /// Walks `server`'s own list of callers and nothing else, so the cost is the
    /// number of requests that server is holding and there is no dependence on
    /// the process tree being built or on a waiter being reachable from init.
    ///
    /// A caller found this way is by construction waiting on this server, which
    /// is the check that matters: without it a server could answer a call
    /// somebody else is in the middle of, and that caller would take the wrong
    /// process's words as its reply.
    static func waiter(
        identity : Badge,
        on server: UnsafeMutablePointer<Process>
    ) -> UnsafeMutablePointer<Process>? {

        guard identity != 0 else { return nil }

        var at = server.pointee.replyTo

        while let candidate = at {
            if candidate.pointee.identity == identity { return candidate }
            at = candidate.pointee.nextWaiter
        }

        return nil
    }


    /// Takes `caller` out of `server`'s list of waiting callers.
    ///
    /// Used by every path that ends a wait: a reply, a caller dying, a server
    /// dying. The list is the only record of who is waiting, so a caller left in
    /// it after its wait ended is a pointer to a process that may be gone.
    @inline(__always)
    static func unlinkWaiter(
        _ caller : UnsafeMutablePointer<Process>,
        from server: UnsafeMutablePointer<Process>
    ) {
        if server.pointee.replyTo == caller {
            server.pointee.replyTo = caller.pointee.nextWaiter

        } else {
            var at = server.pointee.replyTo

            while let node = at {
                if node.pointee.nextWaiter == caller {
                    node.pointee.nextWaiter = caller.pointee.nextWaiter
                    break
                }
                at = node.pointee.nextWaiter
            }
        }

        if server.pointee.deferredReplies > 0 {
            server.pointee.deferredReplies &-= 1
        }

        // Only the list link is cleared here. The other one, "who am I waiting
        // on", lives in the caller's status and goes when that changes, which
        // every path into here either has just done or is about to.
        caller.pointee.nextWaiter = nil
    }


    /// Points `set` at `endpoint`, so a line firing wakes whoever is receiving
    /// there.
    ///
    /// Both directions are written: the set names the endpoint so the interrupt
    /// path knows where to knock, and the endpoint names the set so a `receive`
    /// about to park can ask whether the device has already spoken without
    /// walking a capability table.
    ///
    /// The reference goes one way, set to endpoint. Re-binding lets go of the
    /// previous one first, so a driver that binds twice does not leak the
    /// endpoint it stopped using.
    mutating func bind(
        interrupts set: UnsafeMutablePointer<InterruptSet>,
        to  endpoint  : UnsafeMutablePointer<Endpoint>
    ) {
        guard set.pointee.notify != endpoint else { return }

        unbind(interrupts: set)

        rxRetain(endpoint)

        set.pointee.notify        = endpoint
        endpoint.pointee.signals  = set
    }


    /// Takes `set` off whatever endpoint it was bound to.
    ///
    /// Called when a set is rebound and when it is released. The endpoint's back
    /// pointer has to be cleared here and nowhere else: it is the one link that
    /// outlives its owner if forgotten, and reading it afterwards is reading a
    /// set that has been freed.
    mutating func unbind(interrupts set: UnsafeMutablePointer<InterruptSet>) {

        guard let endpoint = set.pointee.notify else { return }

        set.pointee.notify = nil

        if endpoint.pointee.signals == set {
            endpoint.pointee.signals = nil
        }

        guard rxRelease(endpoint) else { return }

        for i in 0..<endpoints.count where endpoints[i] == endpoint {
            endpoints[i] = nil
            break
        }

        heap.pointee.kfree(endpoint)
    }


    /// Wakes a process receiving on `set`'s bound endpoint, if there is one, and
    /// hands it the lines that fired.
    ///
    /// Answers whether it found somebody. When it did not, the bits stay in
    /// `pending` and the next `receive` on that endpoint collects them without
    /// parking - the same promise `irqWait` has always made, kept in the other
    /// place a driver can be waiting.
    @discardableResult
    mutating func signal(_ set: UnsafeMutablePointer<InterruptSet>) -> Bool {

        guard let endpoint = set.pointee.notify,
              endpoint.pointee.state == .recvBlocked,
              let receiver = endpoint.pointee.queue.popFront()
        else { return false }

        if endpoint.pointee.queue.isEmpty() {
            endpoint.pointee.state = .idle
        }

        Self.deliverNotification(set, to: receiver)

        wake(receiver)

        return true
    }


    /// Writes an interrupt notification into a receiver's registers.
    ///
    /// Shaped exactly like a message so that one `receive` can answer either.
    /// The sender identity is zero, which is the wire value for "no principal":
    /// this did not come from a process, and a server that keys state on the
    /// caller must not find a caller here.
    static func deliverNotification(
        _ set: UnsafeMutablePointer<InterruptSet>,
        to receiver: UnsafeMutablePointer<Process>
    ) {
        guard let context = receiver.pointee.context else { return }
        deliverNotification(set, into: context)
    }

    static func deliverNotification(
        _ set: UnsafeMutablePointer<InterruptSet>,
        into context: UnsafeMutablePointer<AArch64.TrapFrame>
    ) {
        // Collected here rather than left for the receiver to read, for the
        // reason `irqWait` collects them here too: a second line firing between
        // the wake and the return would otherwise overwrite the bits.
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = UInt32(set.pointee.pending)

        Message(
            tag  : MessageTag(packed: (UInt64(InterruptNotification.label) << 8) | 1),
            words: words
        ).write(to: context)

        set.pointee.pending = 0

        context.pointee.x0 = IPCStatus.ok.rawValue

        // No session and no principal: this did not come from a process, so a
        // server keying state on the caller must not find one here.
        context.pointee.x6 = 0
        context.pointee.x7 = IPCDelivery.principal(0)
    }


    @inline(__always)
    mutating func retain(_ cap: Capability) {

        switch cap.target {
            case .endpoint(let endpointPtr):
                rxRetain(endpointPtr)

                // Counted apart from the references, because they answer
                // different questions: how many capabilities keep this endpoint
                // alive, and how many of them could ever take a message off it.
                if cap.rights.contains(.receive) {
                    endpointPtr.pointee.receivers &+= 1
                }

            case .shared  (let sharedMemoryPtr): rxRetain(sharedMemoryPtr)
            case .dma     (let dmaRegionPtr)   : rxRetain(dmaRegionPtr)
            case .interrupt(let setPtr)        : rxRetain(setPtr)
            case .bus     (let busPtr)         : rxRetain(busPtr)
            
            default: break // Targets without reference-counted backing.
        }
    }


    private mutating func release(_ cap: Capability) {

        switch cap.target {
            case .endpoint(let endpointPtr):
                // Before the reference count, because the endpoint may be about
                // to be freed and whoever is queued on it has to be let go
                // while it is still there to be queued on.
                if cap.rights.contains(.receive), endpointPtr.pointee.receivers > 0 {
                    endpointPtr.pointee.receivers &-= 1
                    abandonUnservable(endpointPtr)
                }

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

            case .bus(let busPtr):
                guard rxRelease(busPtr) else { return }

                // Nothing to give back: what was carved out of it holds its own
                // references, and the bus itself never claimed a line.
                heap.pointee.kfree(busPtr)

            case .interrupt(let setPtr):
                guard rxRelease(setPtr) else { return }

                for index in 0..<Int(setPtr.pointee.lineCount) {
                    Kernel.gic.pointee.disableInterrupt(id: setPtr.pointee.lines[index])
                }

                // Before the free, and it has to be: the endpoint holds a back
                // pointer to this set, and an endpoint outliving the set it
                // names would have a `receive` reading freed memory.
                unbind(interrupts: setPtr)

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

        // And an interrupt deadline, which is the other kind this process could
        // be holding. A deadline outliving the process it names is a pointer the
        // scheduler will follow into freed memory.
        IrqWaitSyscall.cancelDeadline(on: process)

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
