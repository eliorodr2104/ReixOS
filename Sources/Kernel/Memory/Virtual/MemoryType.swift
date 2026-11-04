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
    ///
    /// Visibility is all it buys, and the distinction is worth keeping straight
    /// because getting it wrong is silent. This is *Normal* memory: the CPU may
    /// reorder accesses to it as freely as to any other, and the compiler above
    /// it may too. A driver whose protocol is an order - and a virtqueue's is
    /// nothing else - has to say that order itself, with `dmaWriteBarrier` and
    /// `dmaReadBarrier`.
    ///
    /// Inner shareable here, while those barriers name the *outer* domain, and
    /// the two are not in disagreement: shareability on non-cacheable memory
    /// decides who shares a coherency view, and nothing caches this. A barrier's
    /// domain has to reach the other observer, and the other observer is a
    /// device.
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
