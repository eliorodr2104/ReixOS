//
//  SchedulerInterface.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

public protocol SchedulerInterface {
    func addTask(_ process: borrowing UnsafeMutablePointer<Process>)
    func removeTask(_ pid: PID) throws(PPMError)
    
    mutating func selectNextTask() -> UnsafeMutablePointer<Process>?
    
    mutating func onTick() -> Bool
    
    func notifyTaskBlocked(_ processID: PID)
    func notifyTaskYielded(_ processID: PID)
}
