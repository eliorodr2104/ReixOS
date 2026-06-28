//
//  RegionKind.swift
//  ReixOS
//
//  Created by Eliomar on 28/06/2026.
//


public enum RegionKind {
    case shared
    case device
    
    public var memoryType: MemoryType {
        switch self {
            case .shared: .normal
            case .device: .device
        }
    }
    
    
    public var backing: BackingType {
        switch self {
            case .shared: .shared
            case .device: .device
        }
    }
}
