//
//  TypedShellSequenceArena.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public struct TypedShellSequenceArena {
    var sequences = InlineArray<8, ShellSequence?>(repeating: nil)
    var count     = 0

    public init() {}

    /// Closure-local sequence results die after their consumer has copied the
    /// records or read the predicate. Handles below the checkpoint stay live.
    mutating func truncate(to checkpoint: Int) {
        guard checkpoint >= 0, checkpoint <= count else { return }
        for index in checkpoint..<count { sequences[index] = nil }
        count = checkpoint
    }
}
