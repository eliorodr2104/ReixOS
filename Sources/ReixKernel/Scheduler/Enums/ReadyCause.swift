//
//  ReadyCause.swift
//  ReixOS
//

/// Why a ready process carries a `readySince` stamp, and therefore which
/// latency the rotation that runs it settles.
///
/// Only wakes are measured. A process put back after a preemption or a yield
/// was not waiting for anything, and a new one has nothing to be late for.
@usableFromInline
enum ReadyCause: UInt8 {

    /// No measurement pending.
    case none

    /// Made ready by an event: an IPC partner, an interrupt, a child's exit.
    /// `readySince` is the wake.
    case wake

    /// Made ready because a kernel deadline passed. `readySince` is the
    /// instant the deadline was due, which can be earlier than the wake.
    case deadline
}
