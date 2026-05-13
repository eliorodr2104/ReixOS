//
//  LinkedList.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

public struct LinkedList<T: RXEntry> {
    internal var head: UnsafeMutablePointer<T>?
    internal var tail: UnsafeMutablePointer<T>?
    
    internal let minAddress: VirtualAddress?
    internal let maxAddress: VirtualAddress?
    
    public init(
        head: UnsafeMutablePointer<T>?,
        tail: UnsafeMutablePointer<T>?
    ) {
        self.head = head
        self.tail = tail
        
        self.minAddress = nil
        self.maxAddress = nil
    }
    
    public mutating func pushBack(_ element: UnsafeMutablePointer<T>) {
        element.pointee.next = nil
        element.pointee.prev = tail
        
        if let currentTail = tail {
            currentTail.pointee.next = element
            
        } else { head = element }
        
        tail = element
    }
    
    public mutating func popFront() -> UnsafeMutablePointer<T>? {
        guard let elementToReturn = head else {
            return nil
        }
        
        head = elementToReturn.pointee.next
        
        if let newHead = head {
            newHead.pointee.prev = nil
            
        } else { tail = nil }
        
        elementToReturn.pointee.next = nil
        elementToReturn.pointee.prev = nil
        
        return elementToReturn
    }
    
    public mutating func insertBefore(
        element: UnsafeMutablePointer<T>,
        to node: UnsafeMutablePointer<T>
    ) {
        let previous = node.pointee.prev
        
        element.pointee.prev = previous
        element.pointee.next = node
        node.pointee.prev    = element
        
        if let previousNode = previous {
            previousNode.pointee.next = element
            
        } else { head = element }
    }
    
    public mutating func insertAfter(
        element: UnsafeMutablePointer<T>,
        to node: UnsafeMutablePointer<T>
    ) {
        let next = node.pointee.next
        
        element.pointee.prev = node
        element.pointee.next = next
        node.pointee.next    = element
        
        if let nextNode = next {
            nextNode.pointee.prev = element
            
        } else { tail = element }
    }
    
    public mutating func remove(element: UnsafeMutablePointer<T>) -> UnsafeMutablePointer<T>? {
        let prev = element.pointee.prev
        let next = element.pointee.next
        
        if let previousNode = prev {
            previousNode.pointee.next = next
            
        } else { head = next }
        
        if let nextNode = next {
            nextNode.pointee.prev = prev
            
        } else { tail = prev }
        
        element.pointee.next = nil
        element.pointee.prev = nil
        
        return element
    }
    
    public mutating func remove(id: T.IDType) -> UnsafeMutablePointer<T>? {
        var current = head
        
        while let element = current {
            if element.pointee.entryID == id {
                return remove(element: element)
            }
            
            current = element.pointee.next
        }
        
        return nil
    }
}
