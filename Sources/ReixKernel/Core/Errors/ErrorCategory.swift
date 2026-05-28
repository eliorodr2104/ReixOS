//
//  ErrorCategory.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Coarse classification of every `KernelDiagnostic`.
///
/// The tag string is shaped to align with the `Subsystem` tags used by
/// the logger so that an error rendered next to a `[ ERROR ]` prefix
/// keeps the same column width as a `[ BOOT  ]` boot line.
public enum ErrorCategory {
    case allocator
    case memory
    case heap
    case process
    case scheduler
    case elf
    case vma
    case syscall
    case ipc
    case fs
    case kernel

    public var tag: String {
        switch self {
            case .allocator: "[ALLO]"
            case .memory   : "[MEM ]"
            case .heap     : "[HEAP]"
            case .process  : "[PROC]"
            case .scheduler: "[SCHD]"
            case .elf      : "[ELF ]"
            case .vma      : "[VMA ]"
            case .syscall  : "[SYS ]"
            case .ipc      : "[IPC ]"
            case .fs       : "[FS  ]"
            case .kernel   : "[KERN]"
        }
    }
}
