//
//  LaunchOffer.swift
//  ReixOS
//

/// Keeps the bootstrap order explicit so a launch can pause between offers.
public enum LaunchOffer: Equatable {
    case begin
    case binding(Int)
    case commit

    public var acknowledgementIndex: UInt32 {
        switch self {
            case .begin, .commit: return UInt32.max
            case .binding(let index): return UInt32(index)
        }
    }

    public func next(bindings count: Int) -> LaunchOffer {
        switch self {
            case .begin: return count > 0 ? .binding(0) : .commit
            case .binding(let index): return index + 1 < count ? .binding(index + 1) : .commit
            case .commit: return .commit
        }
    }
}
