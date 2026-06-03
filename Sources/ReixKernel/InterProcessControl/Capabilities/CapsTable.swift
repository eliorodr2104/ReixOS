//
//  CapsTable.swift
//  ReixOS
//
//  Created by Eliomar on 31/05/2026.
//


@frozen
public struct CapsTable {
    
    private var caps: InlineArray = InlineArray<16, EndpointCap?>(
        repeating: nil
    ) // (16 * 13) 208 Byte
    
    private var counterElements: UInt = 0 // 8 Byte
    
    
    public mutating func install(_ cap: EndpointCap) -> UInt32? {
        var indexFounded: UInt32?
        for i in 0..<caps.count {
            
            if caps[i] == nil {
                indexFounded = UInt32(i)
                caps[i]      = cap
                
                counterElements &+= 1
                break
            }
            
        }
        
        return indexFounded
    }
    
    
    public mutating func remove(_ cap: EndpointCap) -> Bool {
        
        for i in 0..<caps.count {

            if caps[i] == cap {
                caps[i] = nil
                if counterElements > 0 { counterElements &-= 1 }
                return true
            }
        }

        return false
    }
    
    
    public func resolve(_ handle: UInt32) -> EndpointCap? {
        guard handle < caps.count else { return nil }

        return caps[Int(handle)]
    }
    
    
    public func findFirst(for right: CapRights) -> UInt32? {
        
        var result: UInt32? = nil
        for i in 0..<caps.count {

            if let endpoint = caps[i], endpoint.rights.contains(right) {
                result = UInt32(i)
                break
            }
        }
        
        return result
    }


    /// Revoke the capability at `handle`, freeing the slot. Used to implement
    /// *move* semantics for `grant`: the sender loses the capability once it is
    /// transferred, instead of both processes ending up holding it.
    @discardableResult
    public mutating func remove(_ handle: UInt32) -> EndpointCap? {
        guard handle < caps.count, let cap = caps[Int(handle)] else { return nil }

        caps[Int(handle)] = nil
        if counterElements > 0 { counterElements &-= 1 }
        return cap
    }


    public func hasFreeSlot() -> Bool {
        counterElements < caps.count
    }
}
