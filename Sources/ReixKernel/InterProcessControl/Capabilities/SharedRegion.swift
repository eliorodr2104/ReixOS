//
//  SharedRegion.swift
//  ReixOS
//
//  Created by Eliomar on 24/06/2026.
//

public struct SharedRegion: RXObject {
    
    public static var errorMessageAllocation = "Shared Region error allocation"
    
    public var physicalPage: PhysicalPage
    public var references  : UInt64
    public var pageCount   : UInt32
    
}
