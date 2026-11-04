//
//  StatsPage.swift
//  ReixOS
//
//  Created by Eliomar on 04/08/2026.
//

import Reix

/// Reads the stats page (page 0) under the kernel's seqlock: even `seq`
/// means stable, odd means a writer is mid-update, and a `seq` that changed
/// between the two reads means the data was torn. Attachment replacement
/// changes the generation as well; either change makes the reader retry.
struct StatsPage {
    let base: UnsafeRawPointer

    /// Copies the current `SystemStats` and up to `buffer.count`
    /// `ProcessStats` entries into place. Returns how many were copied.
    func read(
        sys   : inout SystemStats,
        buffer: UnsafeMutableBufferPointer<ProcessStats>
    ) -> (count: Int, generation: UInt32) {

        while true {
            let before = base.load(
                fromByteOffset: StatsExportPage.sequenceOffset,
                as: UInt32.self
            )
            dmbISH()
            if before & 1 != 0 { continue }

            let generation = base.load(fromByteOffset: StatsExportPage.generationOffset, as: UInt32.self)

            sys = base.load(
                fromByteOffset: StatsExportPage.systemOffset,
                as: SystemStats.self
            )

            let processCount = base.load(
                fromByteOffset: StatsExportPage.processCountOffset,
                as: UInt32.self
            )
            let toRead = min(Int(processCount), buffer.count)

            for i in 0..<toRead {
                buffer[i] = base.load(
                    fromByteOffset: StatsExportPage.processSlotsOffset
                        + i * StatsExportPage.processSlotStride,
                    as: ProcessStats.self
                )
            }

            dmbISH()
            let after = base.load(
                fromByteOffset: StatsExportPage.sequenceOffset,
                as: UInt32.self
            )
            let currentGeneration = base.load(fromByteOffset: StatsExportPage.generationOffset, as: UInt32.self)
            if after == before, currentGeneration == generation { return (toRead, generation) }
        }
    }
}
