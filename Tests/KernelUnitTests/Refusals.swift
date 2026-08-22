//
//  Refusals.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.

@testable import Kernel

/// Names the refusal `body` produced, `"none"` when it returned normally.
///
/// The closure is untyped rather than `throws(AllocatorError)`: inside an
/// `#expect` expansion the literal's thrown type is inferred as `any Error`, and a
/// typed parameter makes every call site fail to convert.
func refusal(_ body: () throws -> Void) -> String {
    do {
        try body()
        return "none"

    } catch let error as AllocatorError {
        return switch error {
            case .bytesNotValid      : "bytesNotValid"
            case .fullMemory         : "fullMemory"
            case .addressInvalid     : "addressInvalid"
            case .addressRangeInvalid: "addressRangeInvalid"
            case .pageOrderInvalid   : "pageOrderInvalid"
            case .doubleFreeInvalid  : "doubleFreeInvalid"
        }

    } catch let error as PPMError {
        return switch error {
            case .allocationFailed        : "allocationFailed"
            case .metadataInconsistency   : "metadataInconsistency"
            case .invalidFlags            : "invalidFlags"
            case .protectedMemoryViolation: "protectedMemoryViolation"
            case .initRamError            : "initRamError"
            case .invalidRefCount         : "invalidRefCount"
            case .pageOrderMismatch       : "pageOrderMismatch"
            case .frameNotBlockHead       : "frameNotBlockHead"
        }

    } catch let error as VMAError {
        return switch error {
            case .regionOverlap           : "regionOverlap"
            case .noFreeGap               : "noFreeGap"
            case .permissionMismatch      : "permissionMismatch"
            case .fixedAddressUnavailable : "fixedAddressUnavailable"
            case .invalidLayout           : "invalidLayout"
            case .notImplementedBacking   : "notImplementedBacking"
            case .unownedBacking          : "unownedBacking"
            case .allocationFailed        : "allocationFailed"
            case .mappingFailed           : "mappingFailed"
            case .heapAllocationFailed    : "heapAllocationFailed"
        }

    } catch {
        return "unexpected"
    }
}
