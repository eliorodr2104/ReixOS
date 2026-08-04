//
//  KernelError.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/04/2026.
//

/// Top-level wrapper used by the kernel boot path to forward whatever
/// concrete error walked up the stack.
public enum KernelError: KernelFatal {
    case allocatorError      (response: AllocatorError)
    case physicalMemoryManager(response: PPMError)
    case processManager      (ProcessManagerError)
    case scheduler           (SchedulerError)
    case vma                 (VMAError)
    case elf                 (ElfError)
    case unknown

    @inline(__always)
    public init(_ error: AllocatorError) {
        self = .allocatorError(response: error)
    }

    @inline(__always)
    public init(_ error: PPMError) {
        self = .physicalMemoryManager(response: error)
    }

    @inline(__always)
    public init(_ error: ProcessManagerError) {
        self = .processManager(error)
    }

    @inline(__always)
    public init(_ error: SchedulerError) {
        self = .scheduler(error)
    }

    @inline(__always)
    public init(_ error: VMAError) {
        self = .vma(error)
    }

    @inline(__always)
    public init(_ error: ElfError) {
        self = .elf(error)
    }

    public var description: StaticString {
        switch self {
            case .allocatorError       (let response): response.description
            case .physicalMemoryManager(let response): response.description
            case .processManager       (let response): response.description
            case .scheduler            (let response): response.description
            case .vma                  (let response): response.description
            case .elf                  (let response): response.description
            case .unknown                            : "Kernel Error: unknown failure."
        }
    }
}
