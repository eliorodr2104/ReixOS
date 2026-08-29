//
//  main.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

import KernelHostShims
import Reix
import ReixABI

private var checks = 0
private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: StaticString) {
    checks += 1
    if !condition() {
        failures += 1
        print("TerminalRingHarness failure: \(message)")
    }
}

private func cursor(_ page: UnsafeMutablePointer<UInt8>, _ offset: Int) -> UnsafeMutablePointer<UInt32> {
    UnsafeMutableRawPointer(page.advanced(by: offset)).assumingMemoryBound(to: UInt32.self)
}

private func input(_ sequence: UInt32) -> ReixInputRecord {
    ReixInputRecord(kind: .left, sequence: sequence)!
}

kernel_host_shims_link_anchor()
let inputPage = UnsafeMutablePointer<UInt8>.allocate(capacity: ReixTerminalTransport.pageBytes)
let surfacePage = UnsafeMutablePointer<UInt8>.allocate(capacity: ReixTerminalTransport.pageBytes)
defer { inputPage.deallocate(); surfacePage.deallocate() }

check(ReixTerminalRing.initialize(page: inputPage, role: .input, token: 7), "input proposal")
check(ReixTerminalRing.accept(page: inputPage, role: .input, token: 7, epoch: 9), "input accept")
var producer = ReixTerminalRing(page: inputPage, role: .input, token: 7, epoch: 9)!
var consumer = ReixTerminalRing(page: inputPage, role: .input, token: 7, epoch: 9)!
check(consumer.popInput(sequence: 1) == nil, "empty")
for sequence in 1...ReixTerminalTransport.inputCapacity { check(producer.push(input(UInt32(sequence))), "input FIFO") }
check(!producer.push(input(999)), "input full does not overwrite")
for sequence in 1...ReixTerminalTransport.inputCapacity { check(consumer.popInput(sequence: UInt32(sequence))?.sequence == UInt32(sequence), "input drain FIFO") }
check(producer.push(input(1000)), "input reuse")
check(consumer.popInput(sequence: 1000)?.sequence == 1000, "input reuse drain")
cursor(inputPage, 28).pointee = UInt32.max - 1
cursor(inputPage, 32).pointee = UInt32.max - 1
producer = ReixTerminalRing(page: inputPage, role: .input, token: 7, epoch: 9)!
consumer = ReixTerminalRing(page: inputPage, role: .input, token: 7, epoch: 9)!
check(producer.push(input(1001)), "wrap first push")
check(consumer.popInput(sequence: 1001)?.sequence == 1001, "wrap first pop")
check(producer.push(input(1002)), "wrap zero push")
check(consumer.popInput(sequence: 1002)?.sequence == 1002, "wrap zero pop")
check(cursor(inputPage, 28).pointee == 0 && cursor(inputPage, 32).pointee == 0, "wrap crossed zero")

check(ReixTerminalRing.initialize(page: surfacePage, role: .surface, token: 8), "surface proposal")
check(ReixTerminalRing.accept(page: surfacePage, role: .surface, token: 8, epoch: 10), "surface accept")
let surfaceProducer = ReixTerminalRing(page: surfacePage, role: .surface, token: 8, epoch: 10)!
let surfaceConsumer = ReixTerminalRing(page: surfacePage, role: .surface, token: 8, epoch: 10)!
for sequence in 1...ReixTerminalTransport.surfaceCapacity { check(surfaceProducer.push(ReixTextSurfaceCommand(kind: .newline, sequence: UInt32(sequence))!), "surface fill") }
check(!surfaceProducer.push(ReixTextSurfaceCommand(kind: .newline, sequence: 99)!), "surface full")
for sequence in 1...ReixTerminalTransport.surfaceCapacity { check(surfaceConsumer.popSurface(sequence: UInt32(sequence))?.sequence == UInt32(sequence), "surface FIFO") }
check(surfaceProducer.push(ReixTextSurfaceCommand(kind: .newline, sequence: 100)!), "surface reuse")
check(surfaceConsumer.popSurface(sequence: 100)?.sequence == 100, "surface reuse FIFO")

let corruptions = [0, 4, 6, 8, 10, 12, 16, 24, 36, 40]
for offset in corruptions {
    let saved = inputPage[offset]
    inputPage[offset] ^= 0xFF
    check(ReixTerminalRing(page: inputPage, role: .input, token: 7, epoch: 9) == nil, "header corruption")
    inputPage[offset] = saved
}
check(ReixTerminalRing(page: inputPage, role: .input, token: 8, epoch: 9) == nil, "stale token")
check(ReixTerminalRing(page: inputPage, role: .input, token: 7, epoch: 10) == nil, "stale epoch")
cursor(inputPage, 28).pointee = UInt32(ReixTerminalTransport.inputCapacity + 1)
cursor(inputPage, 32).pointee = 0
check(ReixTerminalRing(page: inputPage, role: .input, token: 7, epoch: 9) == nil, "cursor distance corruption")
cursor(inputPage, 28).pointee = 0
cursor(inputPage, 32).pointee = 0
check(producer.push(input(2000)), "mismatch setup")
check(consumer.popInput(sequence: 2001) == nil && cursor(inputPage, 32).pointee == 0, "mismatch keeps consumer")
inputPage[ReixTerminalTransport.headerBytes] = 0
check(consumer.popInput(sequence: 2000) == nil && cursor(inputPage, 32).pointee == 0, "corrupt slot keeps consumer")

let proposalPage = UnsafeMutablePointer<UInt8>.allocate(capacity: ReixTerminalTransport.pageBytes)
defer { proposalPage.deallocate() }
check(ReixTerminalRing.initialize(page: proposalPage, role: .input, token: 11), "proposal setup")
cursor(proposalPage, 28).pointee = 1
check(!ReixTerminalRing.accept(page: proposalPage, role: .input, token: 11, epoch: 1), "nonempty proposal refused")

if failures == 0 {
    print("TerminalRingHarness passed \(checks) checks")
} else {
    print("TerminalRingHarness failed \(failures) of \(checks) checks")
    exit(code: 1)
}
