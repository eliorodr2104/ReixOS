//
//  LinkedList.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

public struct LinkedList {
    private var head: UnsafeMutablePointer<Process>?
    private var tail: UnsafeMutablePointer<Process>?
    
    public init(
        head: UnsafeMutablePointer<Process>?,
        tail: UnsafeMutablePointer<Process>?
    ) {
        self.head = head
        self.tail = tail
    }
    
    public mutating func pushBack(_ process: UnsafeMutablePointer<Process>) {
        process.pointee.nextProcess = nil
        
        if let currentTail = tail {
            currentTail.pointee.nextProcess = process
            tail = process
            
        } else {
            head = process
            tail = process
        }
        
    }
    
    public mutating func popFront() -> UnsafeMutablePointer<Process>? {
        guard let processToReturn = self.head else {
            return nil
        }
        
        head = processToReturn.pointee.nextProcess
        
        if head == nil {
            tail = nil
        }
        
        processToReturn.pointee.nextProcess = nil
        return processToReturn
    }
    
    public mutating func remove(pid: PID) -> UnsafeMutablePointer<Process>? {
        var previous: UnsafeMutablePointer<Process>? = nil
        var current = head
        
        while let process = current {
            let next = process.pointee.nextProcess

            if process.pointee.pid == pid {
                if let previous = previous {
                    previous.pointee.nextProcess = next
                } else {
                    head = next
                }

                if tail == process {
                    tail = previous
                }

                process.pointee.nextProcess = nil
                return process
            }

            previous = process
            current = next
        }
        
        return nil
    }
}
