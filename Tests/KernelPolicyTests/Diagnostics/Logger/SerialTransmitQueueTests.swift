//
//  SerialTransmitQueueTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel

extension KernelPolicyTestRoot {
@Suite("Bounded serial transmit queue", .serialized)
struct SerialTransmitQueueTests {
    @Test("never-ready UART performs one probe and preserves the queue")
    func neverReady() {
        var queue = SerialTransmitQueue()
        queue.beginRecord()
        queue.append(0x41)
        let committed = queue.endRecord()
        #expect(committed)

        var probes = 0
        let sent = queue.drain(budget: 8) { _ in
            probes += 1
            return false
        }

        #expect(sent == 0)
        #expect(probes == 1)

        var output: [UInt8] = []
        #expect(queue.drain(budget: 8) { output.append($0); return true } == 1)
        #expect(output == [0x41])
    }

    @Test("partial readiness resumes in byte order")
    func partialReady() {
        var queue = SerialTransmitQueue()
        queue.beginRecord()
        for byte in UInt8(1)...5 { queue.append(byte) }
        let committed = queue.endRecord()
        #expect(committed)

        var output: [UInt8] = []
        var ready = 2
        #expect(queue.drain(budget: 5) { byte in
            guard ready > 0 else { return false }
            ready -= 1
            output.append(byte)
            return true
        } == 2)

        #expect(output == [1, 2])
        #expect(queue.drain(budget: 5) { output.append($0); return true } == 3)
        #expect(output == [1, 2, 3, 4, 5])
    }

    @Test("byte budget is an exact hard ceiling")
    func exactBudget() {
        var queue = SerialTransmitQueue()
        queue.beginRecord()
        for byte in UInt8(10)...20 { queue.append(byte) }
        let committed = queue.endRecord()
        #expect(committed)

        var output: [UInt8] = []
        #expect(queue.drain(budget: 0) { output.append($0); return true } == 0)
        #expect(queue.drain(budget: 4) { output.append($0); return true } == 4)
        #expect(output == [10, 11, 12, 13])
    }

    @Test("overflow rolls back a large record and counts it once")
    func largeRecordOverflow() {
        var queue = SerialTransmitQueue()
        queue.beginRecord()
        for index in 0...SerialTransmitQueue.capacity {
            queue.append(UInt8(truncatingIfNeeded: index))
        }

        let committed = queue.endRecord()
        #expect(!committed)
        #expect(queue.droppedRecords == 1)
        #expect(queue.drain(budget: .max) { _ in true } == 0)
    }

    @Test("large multi-line dump drops only whole records")
    func largeDump() {
        var queue = SerialTransmitQueue()
        let lineSize = 64
        let committedLines = SerialTransmitQueue.capacity / lineSize

        for line in 0..<(committedLines + 3) {
            queue.beginRecord()
            for _ in 0..<lineSize {
                queue.append(UInt8(truncatingIfNeeded: line))
            }
            _ = queue.endRecord()
        }

        #expect(queue.droppedRecords == 3)

        var output: [UInt8] = []
        let sent = queue.drain(budget: .max) { output.append($0); return true }
        #expect(sent == SerialTransmitQueue.capacity)
        #expect(output.count == SerialTransmitQueue.capacity)

        for line in 0..<committedLines {
            #expect(output[line * lineSize] == UInt8(truncatingIfNeeded: line))
            #expect(output[(line + 1) * lineSize - 1] == UInt8(truncatingIfNeeded: line))
        }
    }

    @Test("wrap preserves committed record order")
    func wrap() {
        var queue = SerialTransmitQueue()
        queue.beginRecord()
        for index in 0..<(SerialTransmitQueue.capacity - 2) {
            queue.append(UInt8(truncatingIfNeeded: index))
        }
        let firstCommitted = queue.endRecord()
        #expect(firstCommitted)
        let firstDrain = queue.drain(budget: SerialTransmitQueue.capacity - 3) { _ in true }
        #expect(firstDrain == SerialTransmitQueue.capacity - 3)

        queue.beginRecord()
        queue.append(0xA1)
        queue.append(0xA2)
        queue.append(0xA3)
        let secondCommitted = queue.endRecord()
        #expect(secondCommitted)

        var output: [UInt8] = []
        #expect(queue.drain(budget: 8) { output.append($0); return true } == 4)
        #expect(output == [UInt8(truncatingIfNeeded: SerialTransmitQueue.capacity - 3), 0xA1, 0xA2, 0xA3])
    }

    @Test("drain refuses an uncommitted record")
    func reentrancyGuard() {
        var queue = SerialTransmitQueue()
        queue.beginRecord()
        queue.append(0x55)

        var probes = 0
        #expect(queue.drain(budget: 1) { _ in probes += 1; return true } == 0)
        #expect(probes == 0)

        let committed = queue.endRecord()
        #expect(committed)
        #expect(queue.drain(budget: 1) { _ in probes += 1; return true } == 1)
        #expect(probes == 1)
    }
}


}
