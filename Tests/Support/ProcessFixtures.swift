//
//  ProcessFixtures.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.

@testable import Kernel

/// One zeroed `Process` carrying `pid`, allocated for the caller to own.
/// Pair it with `destroyProcess`, or let `withProcesses` do both.
public func makeProcess(pid: PID) -> UnsafeMutablePointer<Process> {
    let process = UnsafeMutablePointer<Process>.allocate(capacity: 1)

    process.initialize(to: Process(
        pid         : pid,
        identity    : UInt32(truncatingIfNeeded: pid),
        addressSpace: AddressSpace(rootTablePhysical: 0, asid: 0),
        context     : nil,
        metadata    : nil
    ))

    return process
}


/// Releases a process `makeProcess` handed out.
public func destroyProcess(_ process: UnsafeMutablePointer<Process>) {
    process.deinitialize(count: 1)
    process.deallocate()
}


/// Runs `body` over one live `Process` per pid, then tears all of them down.
///
/// `resettingStatsIndex` clears the global `ProcessStatsIndex` on both sides of
/// the body, which the suites that register these processes in it need: the
/// index stores raw pointers and would outlive the fixtures otherwise.
public func withProcesses(
    _ pids             : [PID],
    resettingStatsIndex: Bool = false,
    _ body             : ([UnsafeMutablePointer<Process>]) -> Void
) {
    withKernelTestGlobals {
      if resettingStatsIndex { ProcessStatsIndex.reset() }

      let processes = pids.map(makeProcess(pid:))
      defer {
          if resettingStatsIndex { ProcessStatsIndex.reset() }
          for process in processes { destroyProcess(process) }
      }

      body(processes)
    }
}


/// `withProcesses` over the pids `1...count`, the shape most suites want.
public func withProcesses(
    _ count            : Int,
    resettingStatsIndex: Bool = false,
    _ body             : ([UnsafeMutablePointer<Process>]) -> Void
) {
    withProcesses(
        (1...count).map(PID.init),
        resettingStatsIndex: resettingStatsIndex,
        body
    )
}


/// A parent/child tree of `processCount` processes, handed to `body` by its root.
///
/// Two shapes on purpose. Seven processes build the branched tree the preorder
/// and parent-climb assertions need; any other count builds a single chain,
/// which is what the bounded-traversal counts are written against.
public func withProcessTree(
    processCount: Int,
    _ body      : (UnsafeMutablePointer<Process>?) -> Void
) {
    let nodes = (1...processCount).map { makeProcess(pid: PID($0)) }
    defer { for node in nodes { destroyProcess(node) } }

    if nodes.count == 7 {
        link(nodes[0], children: [nodes[1], nodes[4], nodes[6]])
        link(nodes[1], children: [nodes[2], nodes[3]])
        link(nodes[4], children: [nodes[5]])

    } else if nodes.count > 1 {
        for index in 0..<(nodes.count - 1) {
            nodes[index].pointee.family.pushChild(nodes[index + 1])
            nodes[index + 1].pointee.family.parent = nodes[index]
        }
    }

    body(nodes.first)
}


/// Gives `process` the out-of-line `ProcessMetadata` block the machine allocates
/// for it at spawn time, and hands it back so the caller can seed its caps table.
///
/// `makeProcess` leaves the field nil, which is all the suites that only read the
/// hot struct need. Anything reaching `metadata.pointee`, and the capability
/// resolution behind every authority check does, needs a real block: the field is
/// an implicitly unwrapped optional, so a nil one is a crash and not a refusal.
///
/// Pair with `destroyMetadata`, or let `withCurrentProcess` be the whole story.
@discardableResult
public func attachMetadata(
    to process: UnsafeMutablePointer<Process>
) -> UnsafeMutablePointer<ProcessMetadata> {
    let metadata = UnsafeMutablePointer<ProcessMetadata>.allocate(capacity: 1)
    metadata.initialize(to: ProcessMetadata())

    process.pointee.metadata = metadata
    return metadata
}


/// Releases the block `attachMetadata` installed and clears the field.
public func destroyMetadata(of process: UnsafeMutablePointer<Process>) {
    guard let metadata = process.pointee.metadata else { return }

    metadata.deinitialize(count: 1)
    metadata.deallocate()

    process.pointee.metadata = nil
}


/// Runs `body` with `process` installed as the running process, then clears it.
///
/// The kernel reads the current process out of a register (`TPIDR_EL1`) through
/// `get_current_process`; on the host that is `Tests/KernelHostShims`, whose copy is
/// a plain static. It used to be a stateless no-op returning 0, which is why every
/// authority check refused on the host and the success paths were unreachable.
///
/// The clearing is not tidiness. The shim's state is global and outlives the
/// fixtures, so a suite that left a pointer behind would hand the next suite a
/// dangling process to dereference, and `swift test --no-parallel` is what keeps two
/// suites from installing one at the same time.
public func withCurrentProcess(
    _ process: UnsafeMutablePointer<Process>,
    _ body   : () -> Void
) {
    withKernelTestGlobals {
      Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: process)))
      defer { Arch.CPU.setCurrentProcess(0) }

      body()
    }
}


/// Pushes `children` in reverse so the sibling list reads in the given order.
private func link(
    _ parent: UnsafeMutablePointer<Process>,
    children: [UnsafeMutablePointer<Process>]
) {
    for child in children.reversed() {
        parent.pointee.family.pushChild(child)
        child.pointee.family.parent = parent
    }
}
