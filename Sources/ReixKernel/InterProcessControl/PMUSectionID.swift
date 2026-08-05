//
//  PMUSectionID.swift
//  ReixOS
//
//  Created by Eliomar on 05/08/2026.
//


/// Which measured section a `TraceCode.pmuSection` record describes, carried in
/// its `info`.
///
/// Wire constants like every other trace id: the host decoder hardcodes the
/// name against the number. There is one section today and it lives here rather
/// than in `TraceEvent` for that reason; a second one moves the enum, not the
/// numbers.
internal enum PMUSectionID {

    /// The rendezvous send fast path, message write through to the wake.
    static let ipcTransfer: UInt16 = 1
}
