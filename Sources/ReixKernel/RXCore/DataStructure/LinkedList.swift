//
//  LinkedList.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

public struct LinkedList<T: RXEntry> {
    private var head: UnsafeMutablePointer<T>?
    private var tail: UnsafeMutablePointer<T>?
    
    public init(
        head: UnsafeMutablePointer<T>?,
        tail: UnsafeMutablePointer<T>?
    ) {
        self.head = head
        self.tail = tail
    }
    
    public mutating func pushBack(_ element: UnsafeMutablePointer<T>) {
        element.pointee.next = nil
        
        if let currentTail = tail {
            currentTail.pointee.next = element
            tail = element
            
        } else {
            head = element
            tail = element
        }
        
    }
    
    public mutating func popFront() -> UnsafeMutablePointer<T>? {
        guard let elementToReturn = self.head else {
            return nil
        }
        
        head = elementToReturn.pointee.next
        
        if head == nil {
            tail = nil
        }
        
        elementToReturn.pointee.next = nil
        return elementToReturn
    }
    
    public mutating func remove(id: T.IDType) -> UnsafeMutablePointer<T>? {
        var previous: UnsafeMutablePointer<T>? = nil
        var current = head
        
        while let process = current {
            let next = process.pointee.next

            if process.pointee.entryID == id {
                if let previous = previous {
                    previous.pointee.next = next
                } else {
                    head = next
                }

                if tail == process {
                    tail = previous
                }

                process.pointee.next = nil
                return process
            }

            previous = process
            current = next
        }
        
        return nil
    }
}
