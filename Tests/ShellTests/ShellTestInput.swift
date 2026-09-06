//
//  ShellTestInput.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

@inline(__always)
func shellTestKey(
    _ key    : ReixInputKey,
    sequence : UInt32,
    modifiers: ReixInputModifiers = []
) -> ReixInputRecord {
    ReixInputRecord(
        kind: .key,
        modifiers: modifiers,
        sequence: sequence,
        logicalKey: key,
        physicalKey: 0x8000 | key.rawValue
    )!
}
