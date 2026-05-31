//
//  Message+Frame.swift
//  ReixOS
//
//  Created by Eliomar on 31/05/2026.
//


extension Message {

    public init(from frame: AArch64.TrapFrame) {
        var w = InlineArray<4, UInt32>(repeating: 0)
        w[0] = UInt32(truncatingIfNeeded: frame.x2)
        w[1] = UInt32(truncatingIfNeeded: frame.x3)
        w[2] = UInt32(truncatingIfNeeded: frame.x4)
        w[3] = UInt32(truncatingIfNeeded: frame.x5)

        self.init(tag: MessageTag(packed: frame.x1), words: w)
    }

    public func write(to frame: UnsafeMutablePointer<AArch64.TrapFrame>) {
        frame.pointee.x1 = tag.packed()
        frame.pointee.x2 = UInt64(words[0])
        frame.pointee.x3 = UInt64(words[1])
        frame.pointee.x4 = UInt64(words[2])
        frame.pointee.x5 = UInt64(words[3])
    }
}
