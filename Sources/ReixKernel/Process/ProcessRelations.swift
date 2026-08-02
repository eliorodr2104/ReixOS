//
//  ProcessRelations.swift
//  ReixOS
//
//  Created by Eliomar on 29/05/2026.
//


public struct ProcessRelations {
    public var parent: UnsafeMutablePointer<Process>? // 8 Byte
    
    var firstChild   : UnsafeMutablePointer<Process>? // 8 Byte
    var nextSibling  : UnsafeMutablePointer<Process>? // 8 Byte
    var prevSibling  : UnsafeMutablePointer<Process>? // 8 Byte
    
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

        } else if firstChild == element {
            firstChild = next
        }

        if let nextNode = next {
            nextNode.pointee.family.prevSibling = prev
        }

        element.pointee.family.prevSibling = nil
        element.pointee.family.nextSibling = nil
    }
    
    public mutating func removeChild(id: PID) -> UnsafeMutablePointer<Process>? {
        var current = firstChild
        
        while let element = current {
            if element.pointee.pid == id {
                removeChild(element)
                return element
            }
            
            current = element.pointee.family.nextSibling
        }
        
        return nil
    }
    
    public func findChild(id: PID) -> UnsafeMutablePointer<Process>? {
        var current = firstChild
        
        while let element = current {
            if element.pointee.pid == id { return element }
            current = element.pointee.family.nextSibling
        }
        
        return nil
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

    /// Detaches every child without handing it to a new parent.
    ///
    /// Last resort for a dying root: with no ancestor left to adopt them the
    /// children must still lose their `parent`, otherwise they keep naming a
    /// `Process` block that is about to be freed and reused `releaseProcess`
    /// would later unlink itself from a stranger's children list. Orphans
    /// become unreapable and leak; a dangling `parent` corrupts the heap.
    public mutating func orphanChildren() {
        var current = firstChild

        while let child = current {
            current = child.pointee.family.nextSibling

            child.pointee.family.parent      = nil
            child.pointee.family.prevSibling = nil
            child.pointee.family.nextSibling = nil
        }

        firstChild = nil
    }
}
