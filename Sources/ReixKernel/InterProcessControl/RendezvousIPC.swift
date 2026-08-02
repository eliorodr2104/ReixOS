//
//  RendezvousIPC.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


import ReixABI

public struct RendezvousIPC: IPCInterface {
    
    public static var errorMessageAllocation: StaticString = "Failed to allocate IPC on the kernel heap"
    
    var endpoints: InlineArray<64, UnsafeMutablePointer<Endpoint>?>
    var ppm      : UnsafeMutablePointer<KernelPPM>
    var scheduler: UnsafeMutablePointer<KernelScheduler>
    var heap     : UnsafeMutablePointer<KernelHeap>

    /// Earliest `ipcDeadline` armed anywhere, and how many processes hold one.
    ///
    /// `armedDeadlines` counts the processes whose `ipcDeadline` is non-`nil`,
    /// which is why every assignment to that field in this file goes through
    /// `armDeadline`/`disarmDeadline`, including the two rendezvous paths where a
    /// waiter is taken off a queue with its timeout still set. `earliestDeadline`
    /// is only a lower bound on those deadlines, never an exact minimum.
    ///
    /// Both may err in one direction only, count too high:
    /// a process can also leave a wait queue without
    /// passing through this file at all (`ProcessManager.killProcess` unlinks a
    /// blocked victim straight out of `Endpoint.queue`, deadline and all), and
    /// that drop is invisible here. Erring this way costs a scan that finds
    /// nothing, exactly what the old code paid on every single tick; erring the
    /// other way would swallow a real timeout.
    private var earliestDeadline: UInt64? = nil
    private var armedDeadlines  : Int     = 0

    
    init(
        ppm      : UnsafeMutablePointer<KernelPPM>,
        scheduler: UnsafeMutablePointer<KernelScheduler>,
        heap     : UnsafeMutablePointer<KernelHeap>
    ) {
        self.endpoints = InlineArray(repeating: nil)
        self.ppm       = ppm
        self.scheduler = scheduler
        self.heap      = heap
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


            var transferResult: Result<UInt32, IPCError>?
            if grantHandle != UInt32.max {

                transferResult = transferCapability(
                    from   : currentProcess,
                    handler: grantHandle,
                    to     : receiverProcess,
                    rights : grantRights
                )
            }
            
            switch transferResult {
                case .success(let newGrantHandle):
                    receiverProcess.pointee.context!.pointee.x7 = UInt64(newGrantHandle)
            
                case .failure(_), nil:
                    receiverProcess.pointee.context!.pointee.x7 = UInt64(UInt32.max)
            }
            
            
            if endpointPtr.pointee.queue.isEmpty() {
                endpointPtr.pointee.state = .idle
            }
            
            Message(from: frame).write(to: receiverProcess.pointee.context!)

            receiverProcess.pointee.context!.pointee.x6 = ipcTag(
                from   : currentProcess,
                session: capability.badge
            )

            disarmDeadline(on: receiverProcess)

            scheduler.pointee.resume(receiverProcess)

            return .success(.sended)
        }
        
        guard blocking else { return .failure(.wouldBlock) }


        currentProcess.pointee.message       = Message(from: frame)
        currentProcess.pointee.ipcSession    = capability.badge
        currentProcess.pointee.pendingGrant  = grantHandle == UInt32.max ? nil : grantHandle
        currentProcess.pointee.pendingRights = grantRights

        disarmDeadline(on: currentProcess)

        endpointPtr.pointee.queue.pushBack(currentProcess)

        endpointPtr.pointee.state     = .sendBlocked
        currentProcess.pointee.status = .blockedOnSend(endpointPtr)
        
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


            var transferResult: Result<UInt32, IPCError>?
            if let pendingGrant  = senderProcess.pointee.pendingGrant {
                transferResult = transferCapability(
                    from   : senderProcess,
                    handler: pendingGrant,
                    to     : currentProcess,
                    rights : senderProcess.pointee.pendingRights ?? [.send, .receive]
                )
            }
            
            switch transferResult {
                case .success(let newGrantHandle):
                    frame.pointee.x7 = UInt64(newGrantHandle)
                    senderProcess.pointee.pendingGrant  = nil
                    senderProcess.pointee.pendingRights = nil
                    
                case .failure(_), nil:
                    frame.pointee.x7 = UInt64(UInt32.max)
            }
            
        
            if endpointPtr.pointee.queue.isEmpty() {
                endpointPtr.pointee.state = .idle
            }
            
            senderProcess.pointee.message?.write(to: frame)

            frame.pointee.x6 = ipcTag(
                from   : senderProcess,
                session: senderProcess.pointee.ipcSession ?? 0
            )


            if senderProcess.pointee.expectsReply {
                
                displaceReplyLink(of: currentProcess, for: senderProcess)

                currentProcess.pointee.replyTo      = senderProcess
                senderProcess.pointee.replyPartner  = currentProcess
                senderProcess.pointee.status        = .blockedOnReply
                senderProcess.pointee.expectsReply  = false
                
            } else { scheduler.pointee.resume(senderProcess) }
            
            return .success(.sended)
        }
        
        guard blocking else { return .failure(.wouldBlock) }

        endpointPtr.pointee.queue.pushBack(currentProcess)
        endpointPtr.pointee.state     = .recvBlocked
        currentProcess.pointee.status = .blockedOnReceive(endpointPtr)

        if let timeoutTicks {
            
            let (deadline, overflowed) = scheduler.pointee.systemTicks
                .addingReportingOverflow(timeoutTicks)

            armDeadline(
                on      : currentProcess,
                deadline: overflowed ? UInt64.max : deadline
            )

        } else { disarmDeadline(on: currentProcess) }

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

            if endpointPtr.pointee.queue.isEmpty() {
                endpointPtr.pointee.state = .idle
            }

            Message(from: frame).write(to: receiverProcess.pointee.context!)

            receiverProcess.pointee.context!.pointee.x6 = ipcTag(
                from   : currentProcess,
                session: capability.badge
            )

            receiverProcess.pointee.context!.pointee.x7 = UInt64(UInt32.max)

            disarmDeadline(on: receiverProcess)

            displaceReplyLink(of: receiverProcess, for: currentProcess)

            receiverProcess.pointee.replyTo     = currentProcess
            currentProcess.pointee.replyPartner = receiverProcess
            
            currentProcess.pointee.status = .blockedOnReply

            scheduler.pointee.resume(receiverProcess)
            
            return .success(.blocked)
        }
        
        
        // Server not ready

        currentProcess.pointee.message      = Message(from: frame)
        currentProcess.pointee.ipcSession   = capability.badge
        currentProcess.pointee.expectsReply = true
        currentProcess.pointee.status       = .blockedOnSend(endpointPtr)

        disarmDeadline(on: currentProcess)

        endpointPtr.pointee.queue.pushBack(currentProcess)
        endpointPtr.pointee.state = .sendBlocked
        
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

        Message(from: frame).write(to: replyProcess.pointee.context!)

        replyProcess.pointee.context!.pointee.x6 = ipcTag(
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
        
        switch transferResult {
            case .success(let newHandle):
                replyProcess.pointee.context!.pointee.x7 = UInt64(newHandle)
            
            case .failure(_), nil:
                replyProcess.pointee.context!.pointee.x7 = UInt64(UInt32.max)
        }
        
        scheduler.pointee.resume(replyProcess)
        currentProcess.pointee.replyTo    = nil
        replyProcess.pointee.replyPartner = nil
        
        return .success(.sended)
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
            pageCount: UInt32
    ) -> Result<UInt32, IPCError> {
    
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
            target: .shared(sharedRegion),
            badge : Badge(0),
            rights: [.send, .receive, .grant]
        )
        
        guard let handle = process.pointee.metadata.pointee.capsTable.install(capability) else {
            sharedRegion.move().releaseFrame(ppm: ppm)
            heap.pointee.kfree(UnsafeMutableRawPointer(sharedRegion))

            return .failure(.outOfEndpoints)
        }
        
        retain(capability)

        return .success(handle)
    }
    
    public mutating func transferCapability(
        from senderProcess  : UnsafeMutablePointer<Process>,
             handler        : UInt32,
        to   receiverProcess: UnsafeMutablePointer<Process>,
             rights         : CapRights
        
    ) -> Result<UInt32, IPCError> {
        let senderMetadata = senderProcess.pointee.metadata!
        guard let capability = senderMetadata.pointee.capsTable.resolve(handler) else {
            return .failure(.invalidCapability)
        }
        
        guard capability.rights.contains(.grant) else {
            return .failure(.notEnoughRights)
        }
        
        let effective = rights.intersection(capability.rights)
        let receiverCap = Capability(
            target: capability.target,
            badge : capability.badge,
            rights: effective
        )

        
        let receiverMetadata = receiverProcess.pointee.metadata!
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

        let effective = rights.intersection(capability.rights)
        let childCap  = Capability(
            target: capability.target,
            badge : capability.badge,
            rights: effective
        )

        guard child.pointee.metadata.pointee.capsTable.install(at: slot, childCap) else {
            return false
        }

        retain(childCap)

        return true
    }


    /// O(1) answer to "is it worth scanning at all?", for the 100 Hz tick.
    ///
    /// Kept separate from `checkTimeouts` so the timer handler can skip the call
    /// altogether, and non-`mutating` so testing it costs two loads and a
    /// compare; `checkTimeouts` asks the very same question again, because a
    /// caller that forgets to must still not scan for nothing.
    @inline(__always)
    public func hasDeadlineDue(at now: UInt64) -> Bool {
        guard armedDeadlines > 0, let earliest = earliestDeadline else {
            return false
        }

        return earliest <= now
    }


    public mutating func checkTimeouts(now: UInt64) {

        guard hasDeadlineDue(at: now) else { return }

        var survivingEarliest: UInt64? = nil
        var survivingArmed   : Int     = 0

        for i in 0..<endpoints.count {

            if let endpoint = endpoints[i],
               endpoint.pointee.state != .idle {

                var iterator = endpoint.pointee.queue.getIterator()
                while let current: UnsafeMutablePointer<Process> = iterator {
                    let next = current.pointee.next

                    if let deadLine = current.pointee.ipcDeadline {

                        if deadLine <= now {
                            endpoint.pointee.queue.remove(element: current)
                            current.pointee.context?.pointee.x0 = IPCStatus.timeout.rawValue

                            disarmDeadline(on: current)
                            scheduler.pointee.resume(current)

                        } else {
                            survivingArmed   += 1
                            survivingEarliest = survivingEarliest.map { min($0, deadLine) } ?? deadLine
                        }
                    }

                    iterator = next
                }

                if endpoint.pointee.queue.isEmpty() {
                    endpoint.pointee.state = .idle
                }
            }
        }

        earliestDeadline = survivingEarliest
        armedDeadlines   = survivingArmed
    }

    
    // MARK: - Helpers

    /// Arms `deadline` on `process` and folds it into the earliest known one.
    ///
    /// Folding with `min` here is what makes it legal to recompute
    /// `earliestDeadline` only during a scan: a deadline armed between two scans
    /// can pull the next one earlier, never push it later, so the bound stays
    /// on the safe side of every waiter.
    @inline(__always)
    private mutating func armDeadline(
        on process : UnsafeMutablePointer<Process>,
           deadline: UInt64
    ) {
        if process.pointee.ipcDeadline == nil { armedDeadlines += 1 }

        process.pointee.ipcDeadline = deadline
        earliestDeadline            = earliestDeadline.map {
            min($0, deadline)
        } ?? deadline
    }


    /// Disarms whatever deadline `process` was holding.
    ///
    /// `earliestDeadline` is left untouched on purpose, it is only ever read as
    /// a lower bound, and the next scan rebuilds it from the waiters that are
    /// still there; lowering the count without it merely risks one scan that
    /// finds nothing to do.
    @inline(__always)
    private mutating func disarmDeadline(on process: UnsafeMutablePointer<Process>) {
        guard process.pointee.ipcDeadline != nil else { return }

        process.pointee.ipcDeadline = nil
        armedDeadlines              = max(0, armedDeadlines - 1)
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

        scheduler.pointee.resume(abandoned)
        server.pointee.replyTo = nil
    }


    @inline(__always)
    mutating func retain(_ cap: Capability) {

        switch cap.target {
            case .endpoint(let endpointPtr)    : rxRetain(endpointPtr)
            case .shared  (let sharedMemoryPtr): rxRetain(sharedMemoryPtr)
            
            default: break // This because DeviceRegion is not a object
                
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
                guard rxRelease(sharedMemoryPtr) else { return }

                sharedMemoryPtr.move().releaseFrame(ppm: ppm)
                heap.pointee.kfree(UnsafeMutableRawPointer(sharedMemoryPtr))
                
                
            default: break // This because DeviceRegion is not a object
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
