//
//  SchedulerInterface.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

public protocol SchedulerInterface {
    mutating func addTask(_ process: borrowing UnsafeMutablePointer<Process>) throws(SchedulerError)
    mutating func removeTask(_ process: UnsafeMutablePointer<Process>)
    mutating func selectNextTask() -> UnsafeMutablePointer<Process>?
    mutating func onTick() -> Bool
    mutating func yield() -> UnsafeMutablePointer<AArch64TrapFrame>?
    
    mutating func block(_ pid: PID) throws(SchedulerError)
    mutating func wakeUp(_ pid: PID) throws(SchedulerError)
    
    func notifyTaskBlocked(_ processID: PID)
    func notifyTaskYielded(_ processID: PID)
}
