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
        print("TextSurfaceRingHarness failure: \(message)")
    }
}

private func cursor(_ page: UnsafeMutablePointer<UInt8>, _ offset: Int) -> UnsafeMutablePointer<UInt32> {
    UnsafeMutableRawPointer(page.advanced(by: offset)).assumingMemoryBound(to: UInt32.self)
}

kernel_host_shims_link_anchor()
let page = UnsafeMutablePointer<UInt8>.allocate(capacity: ReixTextSurfaceTransport.pageBytes)
defer { page.deallocate() }

check(ReixTextSurfaceRing.initialize(page: page, token: 7), "proposal")
check(ReixTextSurfaceRing.accept(page: page, token: 7, epoch: 9), "accept")
var producer = ReixTextSurfaceRing(page: page, token: 7, epoch: 9)!
var consumer = ReixTextSurfaceRing(page: page, token: 7, epoch: 9)!
check(consumer.pop(sequence: 1) == nil, "empty")
for sequence in 1...ReixTextSurfaceTransport.capacity {
    check(producer.push(ReixTextSurfaceCommand(kind: .newline, sequence: UInt32(sequence))!), "fill")
}
check(!producer.push(ReixTextSurfaceCommand(kind: .newline, sequence: 99)!), "full does not overwrite")
for sequence in 1...ReixTextSurfaceTransport.capacity {
    check(consumer.pop(sequence: UInt32(sequence))?.sequence == UInt32(sequence), "drain FIFO")
}
check(producer.push(ReixTextSurfaceCommand(kind: .newline, sequence: 100)!), "reuse")
check(consumer.pop(sequence: 100)?.sequence == 100, "reuse FIFO")
cursor(page, 28).pointee = UInt32.max - 1
cursor(page, 32).pointee = UInt32.max - 1
producer = ReixTextSurfaceRing(page: page, token: 7, epoch: 9)!
consumer = ReixTextSurfaceRing(page: page, token: 7, epoch: 9)!
check(producer.push(ReixTextSurfaceCommand(kind: .newline, sequence: 101)!), "wrap first push")
check(consumer.pop(sequence: 101)?.sequence == 101, "wrap first pop")
check(producer.push(ReixTextSurfaceCommand(kind: .newline, sequence: 102)!), "wrap zero push")
check(consumer.pop(sequence: 102)?.sequence == 102, "wrap zero pop")
check(cursor(page, 28).pointee == 0 && cursor(page, 32).pointee == 0, "wrap crossed zero")

let corruptions = [0, 4, 6, 8, 10, 12, 16, 24, 36, 40]
for offset in corruptions {
    let saved = page[offset]
    page[offset] ^= 0xFF
    check(ReixTextSurfaceRing(page: page, token: 7, epoch: 9) == nil, "header corruption")
    page[offset] = saved
}
check(ReixTextSurfaceRing(page: page, token: 8, epoch: 9) == nil, "stale token")
check(ReixTextSurfaceRing(page: page, token: 7, epoch: 10) == nil, "stale epoch")
cursor(page, 28).pointee = UInt32(ReixTextSurfaceTransport.capacity + 1)
cursor(page, 32).pointee = 0
check(ReixTextSurfaceRing(page: page, token: 7, epoch: 9) == nil, "cursor distance corruption")
cursor(page, 28).pointee = 0
cursor(page, 32).pointee = 0
check(producer.push(ReixTextSurfaceCommand(kind: .newline, sequence: 2000)!), "mismatch setup")
check(consumer.pop(sequence: 2001) == nil && cursor(page, 32).pointee == 0, "mismatch keeps consumer")
page[ReixTextSurfaceTransport.headerBytes] = 0
check(consumer.pop(sequence: 2000) == nil && cursor(page, 32).pointee == 0, "corrupt slot keeps consumer")

let proposalPage = UnsafeMutablePointer<UInt8>.allocate(capacity: ReixTextSurfaceTransport.pageBytes)
defer { proposalPage.deallocate() }
check(ReixTextSurfaceRing.initialize(page: proposalPage, token: 11), "proposal setup")
cursor(proposalPage, 28).pointee = 1
check(!ReixTextSurfaceRing.accept(page: proposalPage, token: 11, epoch: 1), "nonempty proposal refused")

if failures == 0 {
    print("TextSurfaceRingHarness passed \(checks) checks")
} else {
    print("TextSurfaceRingHarness failed \(failures) of \(checks) checks")
    exit(code: 1)
}
