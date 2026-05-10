//
//  ProcessManagerError.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

public enum ProcessManagerError: Error {
    case managerNotValid
    case programAddressNotValid
    case elfParsingFailed(ElfError)
    case creationProcessFailed(PPMError)
    case allocationPageFailed(PPMError)
    case mappingFailed(PPMError)
    case heapAllocationFailed
    
}
