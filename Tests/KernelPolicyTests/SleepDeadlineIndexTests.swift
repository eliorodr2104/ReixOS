//
//  SleepDeadlineIndexTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import KernelTestSupport

@Suite("Sleep deadline index")
struct SleepDeadlineIndexTests {
    @Test("collisions remove the requested sleeper without hiding survivors")
    func collisionRemoval() {
        withProcesses([1, 65, 129]) { processes in
            var index = SleepDeadlineIndex()
            for process in processes {
                let inserted = index.insert(process)
                #expect(inserted)
            }

            let middle = index.remove(pid: 65)
            let first = index.remove(pid: 1)
            let last = index.remove(pid: 129)
            let duplicate = index.remove(pid: 65)
            #expect(middle == processes[1])
            #expect(first == processes[0])
            #expect(last == processes[2])
            #expect(duplicate == nil)
        }
    }

    @Test("the historical thirty-two sleeper capacity remains bounded")
    func boundedCapacity() {
        withProcesses(Array(1...33).map(PID.init)) { processes in
            var index = SleepDeadlineIndex()
            for process in processes.prefix(32) {
                let inserted = index.insert(process)
                #expect(inserted)
            }
            let overflow = index.insert(processes[32])
            #expect(!overflow)

            let removed = index.remove(pid: 17)
            let reused = index.insert(processes[32])
            #expect(removed == processes[16])
            #expect(reused)
        }
    }
}
