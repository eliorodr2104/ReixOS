//
//  ElfErrors.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/05/2026.
//

public enum ElfError: Error {
    case invalidMagicNumber
    case noLoadableSegments
    case malformedLayout
    case allocationFailed(PPMError)
    case mappingFailed(PPMError)
    
    public var errorDescription: String? {
        switch self {
            case .invalidMagicNumber:
                "The file is not a valid ELF executable (invalid magic number)."
                
            case .noLoadableSegments:
                "The executable does not contain any loadable segments (PT_LOAD)."
                
            case .malformedLayout:
                "The ELF segment layout is malformed or corrupted."
                
            case .allocationFailed(let ppmError):
                ppmError.description
                
            case .mappingFailed(let vmmError):
                vmmError.description
        }
    }
}
