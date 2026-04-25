//
//  MemoryType.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

public enum MemoryType {
    case normal
    case device
    
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
        }
    }
}
