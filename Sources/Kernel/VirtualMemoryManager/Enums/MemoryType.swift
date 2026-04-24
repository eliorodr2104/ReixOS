//
//  MemoryType.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

public enum MemoryType {
    case normal
    case device
    
    var attributes: (mair: MairIndex, share: Shareability) {
        switch self {
            case .normal: return (.normalCacheable, .innerShareable)
            case .device: return (.deviceMemory, .nonShareable)
        }
    }
}
