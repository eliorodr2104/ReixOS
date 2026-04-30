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
}
