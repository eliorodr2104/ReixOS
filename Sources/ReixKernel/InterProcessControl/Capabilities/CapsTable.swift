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


    @discardableResult
    public mutating func install(at slot: UInt32, _ cap: Capability) -> Bool {
        guard slot < caps.count else { return false }

        if caps[Int(slot)] == nil { counterElements &+= 1 }
        caps[Int(slot)] = cap

        return true
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
    
    /// Revoke the capability at `handle`, freeing the slot.
    ///
    /// Two callers: process teardown, dropping everything a dying process held,
    /// and `capDrop`, where a live process gives one capability back. Both go
    /// through `RendezvousIPC` so the target's refcount is released with the
    /// slot, this only forgets the entry.
    ///
    /// `grant` does *not* go through here: `transferCapability` installs a copy
    /// in the receiver and leaves the sender's own slot alone, so a grant shares
    /// the target rather than moving it.
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


    public mutating func mint(
        from handle: UInt32,
        session    : Badge,
        rights     : CapRights
    ) -> UInt32? {
        guard session != 0,
              let source = resolve(handle),
              source.rights.contains(.derive),
              source.badge == 0 else { return nil }

        let effective = rights.intersection(source.rights).subtracting(.derive)

        return install(
            Capability(
                target: source.target,
                badge : session,
                rights: effective
            )
        )
    }


    public func hasFreeSlot() -> Bool {
        counterElements < caps.count
    }
}
