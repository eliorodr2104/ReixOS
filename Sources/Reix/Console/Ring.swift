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
    
    /// Removes and returns the next byte from the ring buffer.
    ///
    /// This method dequeues a single byte from the head of the ring buffer.
    /// A memory barrier (`dmbISH`) ensures proper ordering when the buffer
    /// is shared between processes via shared memory.
    ///
    /// - Returns: The next byte in the buffer, or `nil` if the buffer is empty.
    public func pop() -> UInt8? {
        
        guard head != tail else { return nil }
        
        dmbISH()
        let byte = base.load(fromByteOffset: Self.dataOffset + Int(head), as: UInt8.self)
        head = (head + 1) % UInt32(cap)
        
        return byte
    }
    
    public func nextLineLength() -> Int? {
        
        guard head != tail else { return nil }
        
        let end                = tail
        var safeIteratorString = head
        var lenghtString       = 0
        while safeIteratorString != end {
            
            let byte = base.load(fromByteOffset: Self.dataOffset + Int(safeIteratorString), as: UInt8.self)
            lenghtString += 1
            
            if byte == UInt8(ascii: "\n") { return lenghtString }
            
            safeIteratorString = (safeIteratorString + 1) % UInt32(cap)
        }
        
        return nil
    }
    
    public func reset() {
        head = 0
        tail = 0
    }
}
