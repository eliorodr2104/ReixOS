//
//  ProcessTreeTraversal.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

enum ProcessTreeTraversal {
    
    @discardableResult
    static func forEach(
        from root : UnsafeMutablePointer<Process>?,
        upTo limit: UInt32,
        _    body : (UnsafeMutablePointer<Process>) -> Void
    ) -> UInt32 {
        guard limit != 0, let root else { return 0 }

        var current: UnsafeMutablePointer<Process>? = root
        var visited: UInt32 = 0

        while let node = current {
            body(node)
            visited &+= 1

            if visited == limit { break }
            current = successor(of: node, root: root)
        }

        return visited
    }

    private static func successor(
        of node: UnsafeMutablePointer<Process>,
           root: UnsafeMutablePointer<Process>
    ) -> UnsafeMutablePointer<Process>? {
        if let child = node.pointee.family.firstChild { return child }

        var climber: UnsafeMutablePointer<Process>? = node

        while let at = climber, at != root {
            if let sibling = at.pointee.family.nextSibling { return sibling }
            climber = at.pointee.family.parent
        }

        return nil
    }
}
