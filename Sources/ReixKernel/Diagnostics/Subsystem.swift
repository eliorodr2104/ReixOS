//
//  Subsystem.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Origin of a kernel log line.
///
/// Printed right after the severity tag so the operator can tell at a
/// glance which subsystem produced the message. Width is fixed at 6
/// characters (brackets included) to keep columns aligned across the
/// whole boot log and runtime traces.
public enum Subsystem {
    case kern
    case boot
    case ppm
    case vmm
    case heap
    case gic
    case proc
    case sys
    case tim
    case vma
    case elf
    case sched

    var tag: String {
        switch self {
            case .kern : "[KERN]"
            case .boot : "[BOOT]"
            case .ppm  : "[PPM ]"
            case .vmm  : "[VMM ]"
            case .heap : "[HEAP]"
            case .gic  : "[GIC ]"
            case .proc : "[PROC]"
            case .sys  : "[SYS ]"
            case .tim  : "[TIM ]"
            case .vma  : "[VMA ]"
            case .elf  : "[ELF ]"
            case .sched: "[SCHD]"
        }
    }
}
