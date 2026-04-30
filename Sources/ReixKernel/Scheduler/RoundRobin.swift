//
//  RoundRobin.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

public struct RoundRobin: SchedulerInterface {
    
    private let fifo: UnsafeMutablePointer<LinkedList>
    
    public  var currentProcess: UnsafeMutablePointer<Process>?
    
    private var currentTicks: UInt = 0 // Tick
    private let quantum     : UInt = 100 // One tick is 10ms
    
    init() throws(PPMError) {
        let sizeFIFO = UInt(MemoryLayout<LinkedList>.stride)
        let page = try KernelHeap.kmalloc(sizeFIFO)
        
        guard let fifoPtr = page?.bindMemory(to: LinkedList.self, capacity: 1) else {
            throw .allocationFailed(reason: .fullMemory)
        }
            
        self.fifo = fifoPtr
        self.fifo.initialize(to: LinkedList(head: nil, tail: nil))
    }
    
    
    public func addTask(_ process: UnsafeMutablePointer<Process>) {
        guard process.pointee.status == .new else {
            return
        }
        
        process.pointee.status = .ready
        fifo.pointee.pushBack(process)
    }
    
    public func removeTask(_ processID: PID) {
        
    }
    
    public mutating func selectNextTask() -> UnsafeMutablePointer<Process>? {
        if let current = currentProcess {
            fifo.pointee.pushBack(current)
        }
                
        if let next = fifo.pointee.popFront() {
            currentProcess = next
            
        } else {
            currentProcess = nil
        }
        
        self.currentTicks = 0
        return currentProcess
    }
    
    public mutating func onTick() -> Bool {
        currentTicks &+= 1
        
        if currentTicks == 100 { kprint("Tick") }
        return currentTicks >= quantum
    }
    
    public func notifyTaskBlocked(_ processID: PID) {
        
    }
    
    public func notifyTaskYielded(_ processID: PID) {
        
    }
}
