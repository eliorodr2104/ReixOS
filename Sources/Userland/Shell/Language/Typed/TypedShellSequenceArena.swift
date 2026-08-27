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
}
