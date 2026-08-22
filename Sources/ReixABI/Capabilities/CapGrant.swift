//
//  CapGrant.swift
//  ReixOS
//
//  Wire format for spawn-time capability injection: copy the parent's cap at
//  `sourceHandle` into the child's `targetSlot`, reduced to `rights`.
//

public struct CapGrant {
    public var sourceHandle: UInt32
    public var targetSlot  : UInt32
    public var rights      : UInt32

    public init() {
        self.sourceHandle = 0
        self.targetSlot   = 0
        self.rights       = 0
    }

    public init(
        source: UInt32,
        slot  : UInt32,
        rights: CapRights
    ) {
        self.sourceHandle = source
        self.targetSlot   = slot
        self.rights       = UInt32(rights.rawValue)
    }
}
