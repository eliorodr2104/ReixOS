//
//  RoundRobin.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

public struct RoundRobin: SchedulerInterface {
    
    private static var fifo: LinkedList = LinkedList(head: nil, tail: nil)
        
    private var currentTicks: UInt = 0 // Tick
    private let quantum     : UInt = 100 // One tick is 10ms
    
    public func addTask(_ process: UnsafeMutablePointer<Process>) {
        guard process.pointee.status == .new else {
            return
        }
        
        process.pointee.status = .ready
        Self.fifo.pushBack(process)
    }
    
    public func removeTask(_ processID: PID) {
        
    }
    
    public mutating func selectNextTask() -> UnsafeMutablePointer<Process>? {
        let currentAddr = Arch.CPU.getCurrentProcess()
        
        if let currentPtr = UnsafeMutablePointer<Process>(bitPattern: UInt(currentAddr)) {
            Self.fifo.pushBack(currentPtr)
        }
                
        if let next = Self.fifo.popFront() {
            let nextAddr = VirtualAddress(UInt(bitPattern: next))
            Arch.CPU.setCurrentProcess(nextAddr)
            
            currentTicks = 0
            return next
        }
        
        Arch.CPU.setCurrentProcess(0)
        return nil
    }
    
    public mutating func onTick() -> Bool {
        currentTicks &+= 1
        
        if currentTicks == 100 { kprint("Tick") }
        return currentTicks >= quantum
    }
    
    public mutating func yield() -> UnsafeMutablePointer<AArch64TrapFrame>? {
        if let nextProcess = selectNextTask() {
            return nextProcess.pointee.context
        }
        
        return nil
    }
    
    public func notifyTaskBlocked(_ processID: PID) {
        
    }
    
    public func notifyTaskYielded(_ processID: PID) {
        
    }
}
