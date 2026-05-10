//
//  VMAManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

public struct VMAManager: VMALayout {
    
    public func insert(_ region: VirtualMemoryArea) {
   
    }
    
    public func remove(at address: VirtualAddress) {
        
    }
    
    public func search(at address: VirtualAddress) -> VirtualMemoryArea? {
        return nil
    }
    
    public func findGAP(size: UInt64, aligment: UInt64) -> VirtualAddress {
        return 0
    }
    
    public func split(at address: VirtualAddress) {
        
    }
    
}
