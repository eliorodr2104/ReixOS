//
//  MemoryType.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

public enum MemoryType {
    case normal
    case device

    /// Normal memory with the caches out of the picture, for buffers a device
    /// reads and writes behind the CPU's back.
    ///
    /// Not `.device`: that is strongly ordered and forbids the unaligned and
    /// speculative accesses ordinary code makes, so a driver filling a ring
    /// would be writing through a keyhole. Non-cacheable is what makes what the
    /// CPU wrote visible to a device that never looks in a cache, without the
    /// maintenance operations this kernel does not issue.
    case dma
    
    var attributes: MemoryAttributes {
        return switch self {
            case .normal: MemoryAttributes(
                mair : .normalCacheable,
                share: .innerShareable
            )
                
            case .device: MemoryAttributes(
                mair : .deviceMemory,
                share: .nonShareable
            )

            case .dma: MemoryAttributes(
                mair : .normalNonCacheable,
                share: .innerShareable
            )
        }
    }
}
