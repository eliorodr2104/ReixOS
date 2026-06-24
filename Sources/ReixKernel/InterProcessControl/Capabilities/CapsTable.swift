//
//  CapsTable.swift
//  ReixOS
//
//  Created by Eliomar on 31/05/2026.
//


import ReixABI

@frozen
public struct CapsTable {
    
    private(set) var caps: InlineArray = InlineArray<16, Capability?>(
        repeating: nil
    ) // (16 * 13) 208 Byte
    
    private var counterElements: UInt = 0 // 8 Byte
    
    
    public mutating func install(_ cap: Capability) -> UInt32? {
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
    
    
    public mutating func remove(_ cap: Capability) -> Bool {
        
        for i in 0..<caps.count {

            if caps[i] == cap {
                caps[i] = nil
                if counterElements > 0 { counterElements &-= 1 }
                return true
            }
        }

        return false
    }
    
    /// Revoke the capability at `handle`, freeing the slot. Used to implement
    /// *move* semantics for `grant`: the sender loses the capability once it is
    /// transferred, instead of both processes ending up holding it.
    @discardableResult
    public mutating func remove(handle: Int) -> Capability? {
        guard handle < caps.count, let cap = caps[handle] else { return nil }

        caps[handle] = nil
        if counterElements > 0 { counterElements &-= 1 }
        return cap
    }
    
    public func resolve(_ handle: UInt32) -> Capability? {
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


    /// Derive a new capability to the same endpoint with a fresh `badge` and a
    /// (reduced) `rights` set. Gated by `.derive` on the source cap; the derived
    /// copy never carries `.derive`, so it can't re-derive identities.
    public mutating func derive(
        from handle: UInt32,
        badge      : Badge,
        rights     : CapRights
    ) -> UInt32? {
        guard let source = resolve(handle),
              source.rights.contains(.derive) else {
            return nil
        }

        let effective = rights.intersection(source.rights).subtracting(.derive)

        return install(
            Capability(
                target: source.target,
                badge : badge,
                rights: effective
            )
        )
    }


    public func hasFreeSlot() -> Bool {
        counterElements < caps.count
    }
}
