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
    private let mask: UInt32
    
    public init(
        base      : UnsafeMutableRawPointer,
        regionSize: Int
    ) {
        
        
        let usable = regionSize - Self.dataOffset
        var size   = 1
        while size * 2 <= usable { size *= 2 }

        self.base = base
        self.cap  = size
        self.mask = UInt32(size - 1)
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
        (head & mask) == (tail & mask)
    }
    
    public var count: Int {
        Int((tail &- head) & mask)
    }

    public var isFull: Bool {
        count == cap - 1
    }
    
    public func push(_ byte: UInt8) -> Bool {
        
        let currentTail = tail & mask
        let next        = (currentTail + 1) & mask

        guard next != (head & mask) else { return false }

        base.storeBytes(of: byte, toByteOffset: Self.dataOffset + Int(currentTail), as: UInt8.self)
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
        
        let currentHead = head & mask
        guard currentHead != (tail & mask) else { return nil }
        
        dmbISH()
        let byte = base.load(fromByteOffset: Self.dataOffset + Int(currentHead), as: UInt8.self)
        head = (currentHead + 1) & mask
        
        return byte
    }
    
    public func nextLineLength() -> Int? {
        
        let end      = tail & mask
        var iterator = head & mask

        guard iterator != end else { return nil }
        
        var length = 0
        while iterator != end {
            let byte = base.load(fromByteOffset: Self.dataOffset + Int(iterator), as: UInt8.self)
            length += 1

            if byte == UInt8(ascii: "\n") { return length }

            iterator = (iterator + 1) & mask
        }

        return nil
    }
    
    public func reset() {
        head = 0
        tail = 0
    }
}
