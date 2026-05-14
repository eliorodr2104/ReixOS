//
//  VMAManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

public struct VMAManager {
    
    private var vmaList: LinkedList<VirtualMemoryArea>
    
    init() {
        self.vmaList = LinkedList(
            head      : nil,
            tail      : nil,
            minAddress: 0,
            maxAddress: 0
        )
    }
    
    public func memoryMap(
        size       : UInt64,
        permissions: VMAPermissions,
        type       : BackingType
    ) {
   
    }
    
    public func handlePageFault(at address: VirtualAddress) {
        
    }
    
    public func createGuardPage(for region: VirtualMemoryArea) {

    }
}
