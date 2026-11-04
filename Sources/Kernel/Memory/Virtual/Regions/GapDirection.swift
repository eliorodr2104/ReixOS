//
//  GapDirection.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Direction the free-gap search advances along the VMA address range.
///
/// `.upward` is the default for the brk heap (allocations grow toward
/// higher addresses). `.downward` powers the mmap area which fills from
/// the top down. Until step 5b only `.upward` is implemented; passing
/// `.downward` returns `nil`.
public enum GapDirection {
    case upward
    case downward
}
