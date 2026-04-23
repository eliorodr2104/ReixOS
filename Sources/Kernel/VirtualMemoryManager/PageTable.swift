//
//  PageTable.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

public struct PageTable {
    public let table  : UnsafeMutablePointer<PageTableEntry>
    public let address: PhysicalAddress
    static let size = 512
    
    init(
        page  : consuming PhysicalPage,
        offset: UInt64 = 0
    ) {
        self.address = page.address
        let virtualAddress = UInt(self.address) + UInt(offset)
        
        self.table = UnsafeMutablePointer(bitPattern: virtualAddress)!
        self.table.initialize(
            repeating: PageTableEntry(rawValue: 0),
            count: Self.size
        )
    }
}
