//
//  PipeTake.swift
//  ReixOS
//
//  Created by Eliomar on 24/08/2026.
//


public struct PipeTake {

    public let status: PipeStatus
    public let count : Int
    public let ended : Bool

    public init(
        _ status: PipeStatus,
        _ count : Int  = 0,
          ended : Bool = false
    ) {
        self.status = status
        self.count  = count
        self.ended  = ended
    }
}
