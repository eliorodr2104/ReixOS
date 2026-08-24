//
//  FSExtent.swift
//  ReixOS
//
//  Created by Eliomar on 24/08/2026.
//


/// A run of blocks belonging to one object.
///
/// Runs and not block numbers: a file written once on a fresh disk is one run
/// however big it is, so the common case costs eight bytes instead of one entry
/// per block. What it gives up is scattering, which is why an object that runs
/// out of runs says `tooFragmented` rather than silently doing something worse.
public struct FSExtent {
    public var start: UInt32
    public var count: UInt32

    public init(
        start: UInt32 = 0,
        count: UInt32 = 0
    ) {
        self.start = start
        self.count = count
    }

    public var isEmpty: Bool { count == 0 }
}
