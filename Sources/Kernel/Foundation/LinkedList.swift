//
//  LinkedList.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

/// Doubly linked intrusive list: two words, and nothing a caller does not read.
///
/// The links live in the elements (`RXEntry.prev`/`next`), so the list itself
/// allocates nothing and owns nothing: it is a pair of borrowed pointers, cheap
/// enough to embed by value in `Process`, `Endpoint` and the buddy's per-order
/// table. There is no element count, because `isEmpty()` is the only question
/// anybody asks and `head` already answers it, and no address range, because
/// only the VMA set has one: see `VMAList`.
public struct LinkedList<T: RXEntry> {

    internal var head: UnsafeMutablePointer<T>? // 8 Byte
    internal var tail: UnsafeMutablePointer<T>? // 8 Byte


    public init(
        head: UnsafeMutablePointer<T>?,
        tail: UnsafeMutablePointer<T>?
    ) {
        self.head = head
        self.tail = tail
    }

    public mutating func pushBack(_ element: UnsafeMutablePointer<T>) {
        assert(
            element.pointee.next == nil &&
            element.pointee.prev == nil &&
            head != element,
            "pushBack of a node still linked in a list"
        )

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

        guard node.pointee.prev != nil || head == node,
              node.pointee.next != nil || tail == node
        else { return }

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

        guard node.pointee.prev != nil || head == node,
              node.pointee.next != nil || tail == node
        else { return }

        let next = node.pointee.next

        element.pointee.prev = node
        element.pointee.next = next
        node.pointee.next    = element

        if let nextNode = next {
            nextNode.pointee.prev = element

        } else { tail = element }
    }

    public mutating func remove(element: UnsafeMutablePointer<T>) {
        let prev = element.pointee.prev
        let next = element.pointee.next

        guard prev != nil || head == element,
              next != nil || tail == element
        else { return }

        if let previousNode = prev {
            previousNode.pointee.next = next

        } else { head = next }

        if let nextNode = next {
            nextNode.pointee.prev = prev

        } else { tail = prev }

        element.pointee.next = nil
        element.pointee.prev = nil
    }

    public mutating func remove(id: T.IDType) -> UnsafeMutablePointer<T>? {
        var current = head

        while let element = current {
            if element.pointee.entryID == id {
                remove(element: element)
                return element
            }

            current = element.pointee.next
        }

        return nil
    }

    public func search(id: T.IDType) -> UnsafeMutablePointer<T>? {
        var current = head

        while let element = current {
            if element.pointee.entryID == id {
                return element
            }

            current = element.pointee.next
        }

        return nil
    }


    @inline(__always)
    public func isEmpty() -> Bool {
        head == nil
    }

    public func getIterator() -> UnsafeMutablePointer<T>? {
        return head
    }
}
