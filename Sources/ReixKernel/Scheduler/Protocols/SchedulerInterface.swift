//
//  SchedulerInterface.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

public protocol SchedulerInterface: RXAllocatable {

    /// True while a switch is owed but has not been performed yet.
    ///
    /// A tick that finds the quantum spent cannot always switch on the spot:
    /// the frame it holds may be a nested one taken at EL1, and installing
    /// another task over it would abandon the kernel call underneath. The
    /// request is recorded here and honoured on the way back out to EL0.
    var needsResched: Bool { get }

    /// Records that the running task has outstayed its quantum.
    mutating func requestReschedule()

    mutating func addTask(_ process: borrowing UnsafeMutablePointer<Process>) throws(SchedulerError)
    mutating func unlink(_ process: UnsafeMutablePointer<Process>, in status: ProcessStatus)
    mutating func addZombie(_ process: UnsafeMutablePointer<Process>)
    mutating func selectNextTask() -> UnsafeMutablePointer<Process>?
    mutating func resume(_ process: UnsafeMutablePointer<Process>)
    mutating func onTick() -> Bool
    mutating func yield() -> UnsafeMutablePointer<AArch64TrapFrame>?
    
    mutating func block(_ pid: PID) throws(SchedulerError)
    mutating func wakeUp(_ pid: PID) throws(SchedulerError)
    
    func notifyTaskBlocked(_ processID: PID)
    func notifyTaskYielded(_ processID: PID)
}
