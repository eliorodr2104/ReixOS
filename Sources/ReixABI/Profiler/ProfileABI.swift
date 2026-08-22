//
//  ProfileABI.swift
//  ReixOS
//
//  Created by Eliomar on 22/08/2026.
//


/// The register conventions the two profiling syscalls share, and the map from
/// an operation to the right it answers to.
public enum ProfileABI {

    /// The category `operation` is gated on.
    ///
    /// `pmuProbe` is in here like everything else: it reads the PMU block, and
    /// a caller that may not touch the counters may not count them either.
    public static func category(of operation: ProfileOperation) -> CapRights {
        switch operation {
            case .attachExport: .profileStats
            case .dumpConsole : .profileConsole

            case .enable,
                 .disable,
                 .reset,
                 .setSampleDivider,
                 .pmuProbe: .profileCounters
        }
    }

    public static func authorityHandle(_ rawValue: UInt64) -> UInt32? {
        checkedHandle(rawValue)
    }

    public static func attachHandle(_ rawValue: UInt64) -> UInt32? {
        checkedHandle(rawValue)
    }

    private static func checkedHandle(_ rawValue: UInt64) -> UInt32? {
        guard rawValue <= UInt64(UInt32.max) else { return nil }
        return UInt32(rawValue)
    }
}
