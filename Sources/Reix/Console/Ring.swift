//
//  Ring.swift
//  ReixOS
//
//  Created by Eliomar on 29/06/2026.
//


@frozen
public struct Ring {
    
    static let dataOffset = 8
    
    private var base: UnsafeMutableRawPointer // SHM Buffer
    private let cap : Int
    
    public init(
        base      : UnsafeMutableRawPointer,
        regionSize: Int
    ) {
        self.base = base
        self.cap  = regionSize - Self.dataOffset
    }

    private var head: UInt32 {
        get { base.load(fromByteOffset: 0, as: UInt32.self) }
        
        nonmutating set { base.storeBytes(of: newValue, toByteOffset: 0, as: UInt32.self) }
    }
    
    private var tail: UInt32 {
        get { base.load(fromByteOffset: 4, as: UInt32.self) }
        
        nonmutating set { base.storeBytes(of: newValue, toByteOffset: 4, as: UInt32.self) }
    }
    
    public var isEmpty: Bool {
        head == tail
    }
    
    public func push(_ byte: UInt8) -> Bool {
        
        let next = (tail + 1) % UInt32(cap)
        guard next != head else { return false }
        
        base.storeBytes(of: byte, toByteOffset: Self.dataOffset + Int(tail), as: UInt8.self)
        dmbISH()
        tail = next
        
        return true
    }
    
    public func pop() -> UInt8? {
        
        guard head != tail else { return nil }

        dmbISH()
        let byte = base.load(fromByteOffset: Self.dataOffset + Int(head), as: UInt8.self)
        head = (head + 1) % UInt32(cap)
        
        return byte
    }
    
    public func reset() {
        head = 0
        tail = 0
    }
}
