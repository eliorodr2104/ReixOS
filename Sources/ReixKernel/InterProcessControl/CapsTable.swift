//
//  CapsTable.swift
//  ReixOS
//
//  Created by Eliomar on 31/05/2026.
//


@frozen
public struct CapsTable {
    private var caps: InlineArray<16, EndpointCap?>
    
    
    init() {
        self.caps = InlineArray(repeating: nil)
    }
    
    
    public mutating func install(_ cap: EndpointCap) -> UInt32? {
        
        var indexFounded: UInt32?
        for i in 0..<caps.count {
            
            if caps[i] == nil {
                indexFounded = UInt32(i)
                caps[i] = cap
                break
            }
            
        }
        
        return indexFounded
    }
    
    public func resolve(_ handle: UInt32) -> EndpointCap? {
        guard handle < caps.count else {
            return nil
        }
        
        return caps[Int(handle)]
    }
}
