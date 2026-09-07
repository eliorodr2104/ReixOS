//
//  ELFPlanError.swift
//  ReixOS
//

import ReixABI

public enum ELFPlanError: Error, Equatable {
    case truncated
    case notELF
    case unsupported
    case malformed
    case tooManyHeaders
    case tooManySegments
    case imageTooLarge
    case addressOutsideUserImage
    case writeExecuteConflict
    case entryNotExecutable
}
