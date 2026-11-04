//
//  RegionKind.swift
//  ReixOS
//
//  Created by Eliomar on 28/06/2026.
//


public enum RegionKind {
    case shared
    case device

    /// A buffer a device transfers into or out of. Backed like a shared region,
    /// because it is one: the frames belong to the region object and not to the
    /// address space that mapped them.
    case dma
    
    public var memoryType: MemoryType {
        switch self {
            case .shared: .normal
            case .device: .device
            case .dma   : .dma
        }
    }
    
    
    public var backing: BackingType {
        switch self {
            case .shared: .shared
            case .device: .device
            case .dma   : .shared
        }
    }
}
