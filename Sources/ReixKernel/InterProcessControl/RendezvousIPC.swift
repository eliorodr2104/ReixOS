//
//  RendezvousIPC.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


public struct RendezvousIPC: IPCInterface {
    
    public static var errorMessageAllocation = "Failed to allocate IPC on the kernel heap"
    
    var endpoints: InlineArray<64, UnsafeMutablePointer<Endpoint>?>
    var scheduler: UnsafeMutablePointer<KernelScheduler>
    var heap     : UnsafeMutablePointer<KernelHeap>
    
    
    init(
        scheduler: UnsafeMutablePointer<KernelScheduler>,
        heap     : UnsafeMutablePointer<KernelHeap>
    ) {
        self.endpoints = InlineArray(repeating: nil)
        self.scheduler = scheduler
        self.heap      = heap
    }
    
    
    public mutating func send(
        capability: EndpointCap,
        frame     : AArch64.TrapFrame,
        blocking  : Bool = true
        
    ) -> Result<CommunicationMessageResult, IPCError> {
        
        guard capability.rights.contains(.send) else {
            return .failure(.notEnoughRights)
        }
        
        let endpointPtr = capability.endpoint
        let grantHandle = UInt32(frame.x6)
        
        if endpointPtr.pointee.state == .recvBlocked {
            
            guard let receiverProcess = endpointPtr.pointee.queue.popFront() else {
                return .failure(.noReply)
            }
            
            
            var transferResult: Result<UInt32, IPCError>?
            if grantHandle != UInt32.max {

                guard let currentProcess = Arch.CPU.getCurrentProcess() else {
                    return .failure(.noReply)
                }
                
                transferResult = transferCapability(
                    from   : currentProcess,
                    handler: grantHandle,
                    to     : receiverProcess
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
            
            // Reg x6 used for return badge
            receiverProcess.pointee.context!.pointee.x6 = UInt64(capability.badge)

            scheduler.pointee.resume(receiverProcess)
            
            return .success(.sended)
        }
        
        guard blocking else { return .failure(.wouldBlock) }
        
        
        guard let currentProcess = Arch.CPU.getCurrentProcess() else {
            return .failure(.noReply)
        }
        
        // Iplement Build Message
        currentProcess.pointee.message      = Message(from: frame)
        currentProcess.pointee.ipcBadge     = capability.badge
        currentProcess.pointee.pendingGrant = grantHandle == UInt32.max ? nil : grantHandle
        currentProcess.pointee.ipcDeadline  = nil

        endpointPtr.pointee.queue.pushBack(currentProcess)

        endpointPtr.pointee.state     = .sendBlocked
        currentProcess.pointee.status = .blockedOnSend(endpointPtr)
        
        return .success(.blocked)
        
    }
    
    
    public mutating func receive(
        capability: EndpointCap,
        frame       : UnsafeMutablePointer<AArch64.TrapFrame>,
        blocking    : Bool = true,
        timeoutTicks: UInt64? = nil
        
    ) -> Result<CommunicationMessageResult, IPCError> {
        
        guard capability.rights.contains(.receive) else {
            return .failure(.notEnoughRights)
        }
        
        let endpointPtr  = capability.endpoint
        
        if endpointPtr.pointee.state == .sendBlocked {
            
            guard let senderProcess = endpointPtr.pointee.queue.popFront() else {
                return .failure(.noReply)
            }
            
            guard let currentProcess = Arch.CPU.getCurrentProcess() else {
                return .failure(.noReply)
            }
            
            
            var transferResult: Result<UInt32, IPCError>?
            if let pendingGrant = senderProcess.pointee.pendingGrant {
                transferResult = transferCapability(
                    from   : senderProcess,
                    handler: pendingGrant,
                    to     : currentProcess
                )
            }
            
            switch transferResult {
                case .success(let newGrantHandle):
                    frame.pointee.x7 = UInt64(newGrantHandle)
                    senderProcess.pointee.pendingGrant = nil
                    
                case .failure(_), nil:
                    frame.pointee.x7 = UInt64(UInt32.max)
            }
            
        
            if endpointPtr.pointee.queue.isEmpty() {
                endpointPtr.pointee.state = .idle
            }
            
            senderProcess.pointee.message?.write(to: frame)
            frame.pointee.x6 = UInt64(senderProcess.pointee.ipcBadge ?? 0)
                        
            if senderProcess.pointee.expectsReply {
                currentProcess.pointee.replyTo      = senderProcess
                senderProcess.pointee.status        = .blockedOnReply
                senderProcess.pointee.expectsReply  = false
                
            } else {
                scheduler.pointee.resume(senderProcess)
            }
            
            return .success(.sended)
        }
        
        guard blocking else { return .failure(.wouldBlock) }
        
        guard let currentProcess = Arch.CPU.getCurrentProcess() else {
            return .failure(.noReply)
        }
        

        endpointPtr.pointee.queue.pushBack(currentProcess)
        endpointPtr.pointee.state          = .recvBlocked
        currentProcess.pointee.status      = .blockedOnReceive(endpointPtr)
        currentProcess.pointee.ipcDeadline = timeoutTicks.map { scheduler.pointee.systemTicks + $0 }
        
        return .success(.blocked)
    }
    

    public mutating func call(
        capability: EndpointCap,
        frame     : AArch64.TrapFrame
    ) -> Result<CommunicationMessageResult, IPCError> {
        guard capability.rights.contains(.send) else {
            return .failure(.notEnoughRights)
        }
        
        let endpointPtr = capability.endpoint
        
        // Server is waiting message
        if endpointPtr.pointee.state == .recvBlocked {
            guard let receiverProcess = endpointPtr.pointee.queue.popFront() else {
                return .failure(.noReply)
            }
            
            if endpointPtr.pointee.queue.isEmpty() {
                endpointPtr.pointee.state = .idle
            }
            
            Message(from: frame).write(to: receiverProcess.pointee.context!)
            
            // Reg x6 used for return badge
            receiverProcess.pointee.context!.pointee.x6 = UInt64(capability.badge)
            
            guard let currentProcess = Arch.CPU.getCurrentProcess() else {
                return .failure(.noReply)
            }
            
            receiverProcess.pointee.replyTo = currentProcess
            
            currentProcess.pointee.status = .blockedOnReply

            scheduler.pointee.resume(receiverProcess)
            
            return .success(.blocked)
        }
        
        
        // Server not ready
        
        guard let currentProcess = Arch.CPU.getCurrentProcess() else {
            return .failure(.noReply)
        }
        
        
        currentProcess.pointee.message      = Message(from: frame)
        currentProcess.pointee.ipcBadge     = capability.badge
        currentProcess.pointee.expectsReply = true
        currentProcess.pointee.ipcDeadline  = nil
        currentProcess.pointee.status       = .blockedOnSend(endpointPtr)
        
        endpointPtr.pointee.queue.pushBack(currentProcess)
        endpointPtr.pointee.state = .sendBlocked
        
        return .success(.blocked)
    }
    
            
    public mutating func reply(
        frame: AArch64.TrapFrame
    ) -> Result<CommunicationMessageResult, IPCError> {
                    
        guard let currentProcess = Arch.CPU.getCurrentProcess(),
              let replyProcess = currentProcess.pointee.replyTo else {
            
            return .failure(.noReply)
        }
                
        Message(from: frame).write(to: replyProcess.pointee.context!)
        
        scheduler.pointee.resume(replyProcess)
        currentProcess.pointee.replyTo = nil
        
        return .success(.sended)
    }
    
    public mutating func replyRecv(
        capability: EndpointCap,
        frame     : UnsafeMutablePointer<AArch64.TrapFrame>
    ) -> Result<CommunicationMessageResult, IPCError> {
        guard capability.rights.contains(.receive) else {
            return .failure(.notEnoughRights)
        }
        
        _ = reply(frame: frame.pointee)
        
        return receive(capability: capability, frame: frame)
    }

    
    public mutating func spawnEndpoint(
        for process: UnsafeMutablePointer<Process>
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
    
        let endpoint = heap.pointee.kmalloc(Endpoint.self)
        endpoint.initialize(
            to: Endpoint(
                state: .idle,
                queue: LinkedList(head: nil, tail: nil),
                owner: process.pointee.pid
            )
        )

        endpoints[id] = endpoint
        
        let capability = EndpointCap(
            endpoint: endpoint,
            badge   : Badge(0),
            rights  : [.send, .receive, .grant]
        )
        
        guard let handle = process.pointee.metadata.pointee.capsTable.install(capability) else {
            endpoints[id] = nil
            endpoint.deinitialize(count: 1)
            heap.pointee.kfree(UnsafeMutableRawPointer(endpoint))
            return .failure(.outOfEndpoints)
        }

        return .success(handle)
    }


    /// Reclaim every endpoint created by `pid`, freeing its table slot and heap
    /// block. Called from the exit path so a process that spawned endpoints and
    /// then exited doesn't permanently leak slots out of the fixed 64-entry
    /// table.
    ///
    /// NOTE: this is owner-based reclamation. A capability `grant`ed to another
    /// process points at the same endpoint, so freeing it on the owner's exit
    /// leaves that grantee with a dangling capability — acceptable until the
    /// IPC ownership/lifetime policy is finalized, but worth revisiting (e.g.
    /// refcount endpoints, or block exit while endpoints are still referenced).
    public mutating func releaseEndpoints(of pid: PID) {
        for i in 0..<endpoints.count {
            guard let endpoint = endpoints[i], endpoint.pointee.owner == pid else {
                continue
            }

            endpoints[i] = nil
            endpoint.deinitialize(count: 1)
            heap.pointee.kfree(UnsafeMutableRawPointer(endpoint))
        }
    }
    
    
    public func transferCapability(
        from senderProcess  : UnsafeMutablePointer<Process>,
             handler        : UInt32,
        to   receiverProcess: UnsafeMutablePointer<Process>
        
    ) -> Result<UInt32, IPCError> {
        let senderMetadata = senderProcess.pointee.metadata!
        guard let capability = senderMetadata.pointee.capsTable.resolve(handler) else {
            return .failure(.invalidCapability)
        }
        
        guard capability.rights.contains(.grant) else {
            return .failure(.notEnoughRights)
        }
        
        let receiverMetadata = receiverProcess.pointee.metadata!
        guard let receiverHandle = receiverMetadata.pointee.capsTable.install(capability) else {
            return .failure(.outOfEndpoints)
        }

        // MOVE, not copy: revoke the capability from the sender now that the
        // receiver holds it. Otherwise `grant` duplicated authority — both
        // processes kept the cap (with full rights, including `.grant`), which
        // let a granted capability be re-granted unboundedly.
        senderMetadata.pointee.capsTable.remove(handler)

        return .success(receiverHandle)
    }
    
    
    public func checkTimeouts(now: UInt64) {        
        
        for i in 0..<endpoints.count {
            
            if let endpoint = endpoints[i],
               endpoint.pointee.state != .idle {
                
                var iterator = endpoint.pointee.queue.getIterator()
                while let current: UnsafeMutablePointer<Process> = iterator {
                    let next = current.pointee.next
                    
                    if let deadLine = current.pointee.ipcDeadline,
                       deadLine <= now {
                        
                        endpoint.pointee.queue.remove(element: current)
                        current.pointee.context?.pointee.x0 = IPCStatus.timeout.rawValue
                        
                        current.pointee.ipcDeadline = nil
                        scheduler.pointee.resume(current)
                    }
                    
                    iterator = next
                }
                
                if endpoint.pointee.queue.isEmpty() {
                    endpoint.pointee.state = .idle
                }
            }
        }
    }
}
