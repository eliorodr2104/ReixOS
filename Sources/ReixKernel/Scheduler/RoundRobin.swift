//
//  RoundRobin.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

public struct RoundRobin: SchedulerInterface {
    
    private var ready     : LinkedList = LinkedList(head: nil, tail: nil)
    private var waiting   : LinkedList = LinkedList(head: nil, tail: nil)
    private var terminated: LinkedList = LinkedList(head: nil, tail: nil)
            
    private var currentTicks: UInt = 0   // Tick
    private let quantum     : UInt = 100 // One tick is 10ms
    
    public mutating func addTask(_ process: UnsafeMutablePointer<Process>) throws(SchedulerError) {
        guard process.pointee.status == .new else {
            throw .notNewerProcess
        }
        
        process.pointee.status = .ready
        self.ready.pushBack(process)
    }
    
    public mutating func removeTask(_ process: UnsafeMutablePointer<Process>) {
        terminated.pushBack(process)
    }
    
    public mutating func selectNextTask() -> UnsafeMutablePointer<Process>? {
        let currentAddr = Arch.CPU.getCurrentProcess()
        
        if let currentPtr = UnsafeMutablePointer<Process>(bitPattern: UInt(currentAddr)) {
            if currentPtr.pointee.status == .running {
                currentPtr.pointee.status = .ready
                ready.pushBack(currentPtr)
            }
        }
                
        if let next = ready.popFront() {
            let nextAddr = VirtualAddress(UInt(bitPattern: next))
            Arch.CPU.setCurrentProcess(nextAddr)
            next.pointee.status = .running
            
            currentTicks = 0
            return next
        }
        
        Arch.CPU.setCurrentProcess(0)
        return nil
    }
    
    public mutating func onTick() -> Bool {
        currentTicks &+= 1
        
        return currentTicks >= quantum
    }
    
    public mutating func yield() -> UnsafeMutablePointer<AArch64TrapFrame>? {
        if let nextProcess = selectNextTask() {
            return nextProcess.pointee.context
        }
        
        return nil
    }
    
    public mutating func block(_ pid: PID) throws(SchedulerError) {
        let currentAddr = Arch.CPU.getCurrentProcess()
        guard let process = UnsafeMutablePointer<Process>(bitPattern: UInt(currentAddr)) else {
            throw .processNotExist
        }
        
        process.pointee.status = .waiting
        waiting.pushBack(process)
        
        if let next = ready.popFront() {
            let nextAddr = VirtualAddress(UInt(bitPattern: next))
            Arch.CPU.setCurrentProcess(nextAddr)
            next.pointee.status = .running
            
            currentTicks = 0
        } else { Arch.CPU.setCurrentProcess(0) }
    }
    
    public mutating func wakeUp(_ pid: PID) throws(SchedulerError) {
        guard let process = waiting.remove(pid: pid) else {
            throw .processNotExist
        }
        
        process.pointee.status = .ready
        ready.pushBack(process)
    }
    
    public func notifyTaskBlocked(_ processID: PID) {
        
    }
    
    public func notifyTaskYielded(_ processID: PID) {
        
    }
}
