//
//  FrameInfo.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//

@frozen
public struct FrameInfo {
    var refCount : UInt32
    var order    : UInt8
    var flags    : UInt8
    var heapShift: UInt8 // Contains pow shift for size bucket
    
    private let _padding: UInt8 // Align to 8Bytes
    
    init(
        refCount : UInt32,
        order    : UInt8,
        flags    : UInt8,
        heapShift: UInt8 = 0 // Zero value is for not heap page
        
    ) {
        self.refCount  = refCount
        self.order     = order
        self.flags     = flags
        self.heapShift = heapShift
        self._padding  = 0
    }
    
    init() {
        self.refCount  = 0
        self.order     = 0
        self.flags     = 0
        self.heapShift = 0
        self._padding  = 0
    }
}
