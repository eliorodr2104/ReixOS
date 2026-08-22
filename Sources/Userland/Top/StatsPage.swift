//
//  StatsPage.swift
//  ReixOS
//
//  Created by Eliomar on 04/08/2026.
//

import Reix

/// Reads the stats page (page 0) under the kernel's seqlock: even `seq`
/// means stable, odd means a writer is mid-update, and a `seq` that changed
/// between the two reads means the data was torn. Both cases just retry.
struct StatsPage {
    let base: UnsafeRawPointer

    /// Copies the current `SystemStats` and up to `buffer.count`
    /// `ProcessStats` entries into place. Returns how many were copied.
    func read(
        sys   : inout SystemStats,
        buffer: UnsafeMutableBufferPointer<ProcessStats>
    ) -> Int {

        while true {
            let before = base.load(fromByteOffset: 0, as: UInt32.self)
            dmbISH()
            if before & 1 != 0 { continue }

            sys = base.load(fromByteOffset: 8, as: SystemStats.self)

            let processCount = base.load(fromByteOffset: 64, as: UInt32.self)
            let toRead       = min(Int(processCount), buffer.count)

            for i in 0..<toRead {
                buffer[i] = base.load(fromByteOffset: 72 + i * 48, as: ProcessStats.self)
            }

            dmbISH()
            let after = base.load(fromByteOffset: 0, as: UInt32.self)
            if after == before { return toRead }
        }
    }
}
