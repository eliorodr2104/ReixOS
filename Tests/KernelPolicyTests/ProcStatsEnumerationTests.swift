//
//  ProcStatsEnumerationTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// `.serialized` orders this suite's own tests; it does not stop another suite
/// from running beside it, and `ProcessStatsIndex` is one global tree. The run
/// needs `swift test --no-parallel` (see the `test` target in the Makefile).
@Suite("ProcStats enumeration", .serialized)
struct ProcStatsEnumerationTests {
    @Test("empty index has no successor")
    func empty() {
        ProcessStatsIndex.reset()
        #expect(ProcessStatsIndex.successor(after: 0) == nil)
    }

    @Test("one process is returned once")
    func oneProcess() {
        withProcesses([7], resettingStatsIndex: true) { processes in
            ProcessStatsIndex.insert(processes[0])

            #expect(ProcessStatsIndex.successor(after: 0)?.pointee.pid == 7)
            #expect(ProcessStatsIndex.successor(after: 7) == nil)
        }
    }

    @Test("sixteen processes are ordered by pid")
    func sixteenProcesses() {
        let pids: [PID] = [16, 4, 12, 2, 8, 14, 6, 10, 1, 15, 3, 13, 5, 11, 7, 9]

        withProcesses(pids, resettingStatsIndex: true) { processes in
            for process in processes { ProcessStatsIndex.insert(process) }
            #expect(enumeratedPIDs() == Array(1...16).map(UInt64.init))
        }
    }

    @Test("more than sixteen processes stay subquadratic")
    func moreThanSixteenProcesses() {
        let count = 65
        let pids = (1...count).reversed().map(UInt64.init)

        withProcesses(pids, resettingStatsIndex: true) { processes in
            for process in processes { ProcessStatsIndex.insert(process) }

            ProcessStatsIndex.resetLookupSteps()
            #expect(enumeratedPIDs() == (1...count).map(UInt64.init))
            #expect(ProcessStatsIndex.lookupSteps <= UInt64((count + 1) * 8))
        }
    }

    @Test("removed sparse slots are skipped without changing order")
    func sparseRemoval() {
        let pids = Array(1...24).map(UInt64.init)

        withProcesses(pids, resettingStatsIndex: true) { processes in
            for process in processes { ProcessStatsIndex.insert(process) }
            for index in [0, 3, 7, 15, 23] { ProcessStatsIndex.remove(processes[index]) }

            #expect(enumeratedPIDs() == [2, 3, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 22, 23])
        }
    }

    @Test("duplicate pointer and duplicate pid are rejected without corruption")
    func duplicateInsertion() {
        withProcesses([7, 7], resettingStatsIndex: true) { processes in
            #expect(ProcessManager.registerForProcStats(processes[0]))
            #expect(!ProcessManager.registerForProcStats(processes[0]))
            #expect(!ProcessManager.registerForProcStats(processes[1]))
            #expect(ProcessStatsIndex.isValidForTesting)
            #expect(enumeratedPIDs() == [7])
            #expect(ProcessManager.unregisterForProcStats(processes[0]))
            #expect(!ProcessManager.unregisterForProcStats(processes[0]))
        }
    }

    @Test("rotations preserve AVL links heights and root")
    func rotations() {
        for pids in [[3, 2, 1], [1, 2, 3], [3, 1, 2], [1, 3, 2]] {
            withProcesses(pids.map(UInt64.init), resettingStatsIndex: true) { processes in
                for process in processes { #expect(ProcessManager.registerForProcStats(process)) }
                #expect(ProcessStatsIndex.rootPIDForTesting == 2)
                #expect(ProcessStatsIndex.isValidForTesting)
            }
        }
    }

    @Test("removing root and a two-child node preserves AVL invariants")
    func structuralRemoval() {
        let pids = Array(1...15).map(UInt64.init)

        withProcesses(pids, resettingStatsIndex: true) { processes in
            for process in processes { #expect(ProcessManager.registerForProcStats(process)) }
            #expect(ProcessStatsIndex.isValidForTesting)

            let rootPID = ProcessStatsIndex.rootPIDForTesting!
            let root = processes[Int(rootPID - 1)]
            #expect(root.pointee.procStatsLeft != nil)
            #expect(root.pointee.procStatsRight != nil)
            #expect(ProcessManager.unregisterForProcStats(root))
            #expect(ProcessStatsIndex.isValidForTesting)
            #expect(enumeratedPIDs() == pids.filter { $0 != rootPID })

            let twoChild = processes[3]
            #expect(twoChild.pointee.procStatsLeft != nil)
            #expect(twoChild.pointee.procStatsRight != nil)
            #expect(ProcessManager.unregisterForProcStats(twoChild))
            #expect(ProcessStatsIndex.isValidForTesting)
            #expect(enumeratedPIDs() == pids.filter { $0 != rootPID && $0 != 4 })
        }
    }

    @Test("wire records retain their ABI limits")
    func abiLimits() {
        #expect(MemoryLayout<SystemStats>.size == 56)
        #expect(MemoryLayout<SystemStats>.alignment == 8)
        #expect(MemoryLayout<ProcessStats>.size == 48)
        #expect(MemoryLayout<ProcessStats>.stride == 48)
        #expect(MemoryLayout<ProcessStats>.alignment == 8)
        #expect(ProcessStats().name.count == 16)
        #expect(MemoryLayout<Process>.stride <= 256)
        #expect(MemoryLayout<Capability>.stride == 24)
        #expect(MemoryLayout<ProcessMetadata>.stride <= 1024)
    }

    private func enumeratedPIDs() -> [PID] {
        var result: [PID] = []
        var cursor: PID = 0

        while let process = ProcessStatsIndex.successor(after: cursor) {
            cursor = process.pointee.pid
            result.append(cursor)
        }

        return result
    }
}
