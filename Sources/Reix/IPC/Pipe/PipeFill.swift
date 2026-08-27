//
//  PipeFill.swift
//  ReixOS
//
//  Created by Eliomar on 24/08/2026.
//


public struct PipeFill {

    public let status: PipeStatus
    public let count : Int

    public init(
        _ status: PipeStatus,
        _ count : Int = 0
    ) {
        self.status = status
        self.count  = count
    }
}
