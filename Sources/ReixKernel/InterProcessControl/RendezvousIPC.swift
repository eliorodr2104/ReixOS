//
//  RendezvousIPC.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

// Move to file separatly
public enum CommunicationMessageResult {
    case sended
    case blocked
}


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
        frame     : AArch64.TrapFrame
        
    ) -> Result<CommunicationMessageResult, IPCError> {
        
        guard capability.rights.contains(.send) else {
            return .failure(.notEnoughRights)
        }
        
        let endpointPtr = capability.endpoint
        if endpointPtr.pointee.state == .recvBlocked {
            
            guard let receiverProcess = endpointPtr.pointee.queue.popFront() else {
                return .failure(.noReply)
            }
            
            if endpointPtr.pointee.queue.isEmpty() {
                endpointPtr.pointee.state = .idle
            }
            
            Message(from: frame).write(to: receiverProcess.pointee.context!)
            
            // Reg x6 used for return badge
            receiverProcess.pointee.context!.pointee.x6 = UInt64(capability.badge.raw)

            scheduler.pointee.resume(receiverProcess)
            
            return .success(.sended)
        }
        
        
        let currentProcessRaw = Arch.CPU.getCurrentProcess()
        guard let currentProcess = UnsafeMutablePointer<Process>(
            bitPattern: UInt(currentProcessRaw)
        ) else { return .failure(.noReply) }
        
        // Iplement Build Message
        currentProcess.pointee.message  = Message(from: frame)
        currentProcess.pointee.ipcBadge = capability.badge
        
        endpointPtr.pointee.queue.pushBack(currentProcess)
        
        endpointPtr.pointee.state     = .sendBlocked
        currentProcess.pointee.status = .blockedOnSend(endpointPtr)
        
        return .success(.blocked)
        
    }
    
    
    public mutating func receive(
        capability: EndpointCap,
        frame     : UnsafeMutablePointer<AArch64.TrapFrame>
    ) -> Result<CommunicationMessageResult, IPCError> {
        
        guard capability.rights.contains(.receive) else {
            return .failure(.notEnoughRights)
        }
        
        let endpointPtr = capability.endpoint
        if endpointPtr.pointee.state == .sendBlocked {
            
            guard let senderProcess = endpointPtr.pointee.queue.popFront() else {
                return .failure(.noReply)
            }
            
            if endpointPtr.pointee.queue.isEmpty() {
                endpointPtr.pointee.state = .idle
            }
            
            senderProcess.pointee.message?.write(to: frame)
            frame.pointee.x6 = UInt64(senderProcess.pointee.ipcBadge?.raw ?? 0)
                        
            scheduler.pointee.resume(senderProcess)
            
            return .success(.sended)
        }
        
        
        let currentProcessRaw = Arch.CPU.getCurrentProcess()
        guard let currentProcess = UnsafeMutablePointer<Process>(
            bitPattern: UInt(currentProcessRaw)
        ) else { return .failure(.noReply) }
        

        endpointPtr.pointee.queue.pushBack(currentProcess)
        endpointPtr.pointee.state = .recvBlocked
        currentProcess.pointee.status = .blockedOnReceive(endpointPtr)
        
        return .success(.blocked)
    }
    
    public mutating func call() {
        
    }
            
    public mutating func reply() {
                    
    }
    
    public mutating func replyRecv() {
        
    }

    
    public mutating func spawnEndpoint(
        for process: UnsafeMutablePointer<Process>
    ) -> Result<UInt32, IPCError> {
        
        var endpointID: Int? = nil
        for i in 0..<endpoints.count {
            
            if endpoints[i] != nil {
                endpointID = i
                break
            }
        }
        
        guard let id = endpointID else {
            return .failure(.notFoundFreeEndpoint)
        }
        
        
        // Need modify kmalloc, because write a poem is not scalar code
        let endpoint = heap.pointee.kmalloc(Endpoint.self)
        
        return .success(0)
    }
}
