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
        currentProcess.pointee.message       = Message(from: frame)
        currentProcess.pointee.ipcBadge      = capability.badge
        currentProcess.pointee.pendingGrant  = grantHandle == UInt32.max ? nil : grantHandle
        currentProcess.pointee.pendingRights = grantRights 
        currentProcess.pointee.ipcDeadline   = nil

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
        
        if endpointPtr.pointee.state == .sendBlocked {
            
            guard let senderProcess = endpointPtr.pointee.queue.popFront() else {
                return .failure(.noReply)
            }
            
            guard let currentProcess = Arch.CPU.getCurrentProcess() else {
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
            frame.pointee.x6 = UInt64(senderProcess.pointee.ipcBadge ?? 0)
                        
            if senderProcess.pointee.expectsReply {
                currentProcess.pointee.replyTo      = senderProcess
                senderProcess.pointee.replyPartner  = currentProcess
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
            
            receiverProcess.pointee.replyTo     = currentProcess
            currentProcess.pointee.replyPartner = receiverProcess
            
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
    
        let endpoint = heap.pointee.kmalloc(Endpoint.self)
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
    
        let endpoint = heap.pointee.kmalloc(Endpoint.self)
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
        
        // Record the seeded handle so the child can discover it through the
        // `parentEndpoint` syscall, instead of relying on a fixed slot.
        child.pointee.metadata.pointee.parentEndpoint = childEndpointHandle

        return .success(parentEndpointHandle)
    }
    
    public mutating func createShared(
        for process  : UnsafeMutablePointer<Process>,
            page     : consuming PhysicalPage,
            pageCount: UInt32
    ) -> Result<UInt32, IPCError> {
    
        let sharedRegion = heap.pointee.kmalloc(SharedRegion.self)
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
    
    
    // MARK: - Helpers
    
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
    
    public mutating func releaseCapabilities(of process: UnsafeMutablePointer<Process>) {
        guard let metadata = process.pointee.metadata else { return }
        
        for i in 0..<metadata.pointee.capsTable.caps.count where metadata.pointee.capsTable.caps[i] != nil {
            let capability = metadata.pointee.capsTable.caps[i]!

            release(capability)
            metadata.pointee.capsTable.remove(handle: i)
            
        }
    }
    
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
