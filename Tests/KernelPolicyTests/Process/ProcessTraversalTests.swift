//
//  ProcessTrasversalTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import KernelTestSupport

extension KernelPolicyTestRoot {
@Suite("Bounded process traversal")
struct ProcessTraversalTests {
    @Test("zero limit visits nothing")
    func zero() {
        withProcessTree(processCount: 20) { root in
            var callbacks = 0
            let visited = ProcessTreeTraversal.forEach(from: root, upTo: 0) { _ in callbacks += 1 }

            #expect(visited == 0)
            #expect(callbacks == 0)
        }
    }

    @Test("limit sixteen stops a tree containing more processes")
    func bounded() {
        withProcessTree(processCount: 20) { root in
            var pids: [PID] = []
            let visited = ProcessTreeTraversal.forEach(from: root, upTo: 16) { process in
                pids.append(process.pointee.pid)
            }

            #expect(visited == 16)
            #expect(pids == Array(1...16).map(PID.init))
        }
    }

    @Test("limit above population visits the complete tree")
    func belowLimit() {
        withProcessTree(processCount: 5) { root in
            var callbacks = 0
            let visited = ProcessTreeTraversal.forEach(from: root, upTo: 16) { _ in callbacks += 1 }

            #expect(visited == 5)
            #expect(callbacks == 5)
        }
    }

    @Test("branched tree preserves preorder and stops before parent climb")
    func branched() {
        withProcessTree(processCount: 7) { root in
            guard let root else {
                Issue.record("missing root")
                return
            }

            let first = root.pointee.family.firstChild!
            let second = first.pointee.family.firstChild!
            let third = second.pointee.family.nextSibling!

            var allPids: [PID] = []
            let allVisited = ProcessTreeTraversal.forEach(from: root, upTo: 16) { process in
                allPids.append(process.pointee.pid)
            }

            #expect(allVisited == 7)
            #expect(allPids == [1, 2, 3, 4, 5, 6, 7])

            var pids: [PID] = []
            let visited = ProcessTreeTraversal.forEach(from: root, upTo: 4) { process in
                pids.append(process.pointee.pid)
            }

            #expect(visited == 4)
            #expect(pids == [root.pointee.pid, first.pointee.pid, second.pointee.pid, third.pointee.pid])
        }
    }
}


}
