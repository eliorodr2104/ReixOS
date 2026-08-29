//
//  ShellField.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public enum ShellField: UInt16, Equatable {

    case status                   = 1
    case freeBlocks               = 2
    case reclaimableBlocks        = 3
    case claimedTwice             = 4
    case strayNames               = 5
    case duplicateNames           = 6
    case tooManyContainers        = 7
    case safeToServe              = 8
    case text                     = 9
    case complete                 = 10
    case ownedButFree             = 11
    case impossible               = 12
    case duplicateTargets         = 13
    case brokenEntries            = 14
    case nameScrubBudgetExhausted = 15
    case wrongQuota               = 16
    case strayCharges             = 17
    case scrubDepth               = 18
    case quotasChecked            = 19
    case selfParented             = 20
    case roomsMended              = 21
    case mapMended                = 22
}
