//
//  EnvironmentBinding.swift
//  ReixOS
//

/// Semantic capability names used by the transactional environment bootstrap.
/// Their values deliberately match the temporary `BootCap` vocabulary; the
/// received handle itself may occupy any free slot.
public enum EnvironmentBinding: UInt32 {
    case console        = 1
    case nameServer     = 2
    case profiler       = 6
    case terminal       = 8
    case container      = 10
    case shared         = 11
    case block          = 14
    case profileMarker  = 15
    case inputSource    = 16
    case inputConsumer  = 17
    case inputFocus     = 18
    case serialReader   = 19
    case serialWriter   = 20
    case programs       = 21
    case processServer  = 22
    case sessionControl = 23
}
