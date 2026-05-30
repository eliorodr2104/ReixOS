//
//  ProcessRelations.swift
//  ReixOS
//
//  Created by Eliomar on 29/05/2026.
//


public struct ProcessRelations {
    public var parent: UnsafeMutablePointer<Process>?
    
    var firstChild   : UnsafeMutablePointer<Process>?
    var nextSibling  : UnsafeMutablePointer<Process>?
    var prevSibling  : UnsafeMutablePointer<Process>?
    
    init() {
        self.parent      = nil
        self.firstChild  = nil
        self.nextSibling = nil
        self.prevSibling = nil
    }
    
    public mutating func pushChild(_ element: UnsafeMutablePointer<Process>) {
        element.pointee.family.prevSibling = nil
        element.pointee.family.nextSibling = firstChild

        firstChild?.pointee.family.prevSibling = element
        firstChild = element
    }

    public mutating func removeChild(_ element: UnsafeMutablePointer<Process>) {
        let prev = element.pointee.family.prevSibling
        let next = element.pointee.family.nextSibling

        if let previousNode = prev {
            previousNode.pointee.family.nextSibling = next
            
        } else { firstChild = next }

        if let nextNode = next {
            nextNode.pointee.family.prevSibling = prev
        }

        element.pointee.family.prevSibling = nil
        element.pointee.family.nextSibling = nil
    }
    
    public mutating func reparent(newParent: UnsafeMutablePointer<Process>) {
        guard let head = firstChild else { return }
        
        var tail = head
        tail.pointee.family.parent = newParent
        
        while let next = tail.pointee.family.nextSibling {
            tail = next
            next.pointee.family.parent = newParent
        }
        
        tail.pointee.family.nextSibling = newParent.pointee.family.firstChild
        newParent.pointee.family.firstChild?.pointee.family.prevSibling = tail
        newParent.pointee.family.firstChild = head

        firstChild = nil
    }
}
