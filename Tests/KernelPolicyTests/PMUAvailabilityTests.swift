//
//  PMUAvailabilityTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.

import Testing
@testable import Kernel

private enum FakePMURegisters: PMURegisterAccess {
    static var debugFeatures: UInt64 = 0
    static var pmcr: UInt64 = 0
    static var configureCalls = 0
    static var pmcrReads = 0

    static func readDebugFeatures() -> UInt64 { debugFeatures }
    static func configure() { configureCalls += 1 }
    static func readPMCR() -> UInt64 {
        pmcrReads += 1
        return pmcr
    }

    static func reset(debugFeatures: UInt64, pmcr: UInt64 = 0) {
        self.debugFeatures = debugFeatures
        self.pmcr = pmcr
        configureCalls = 0
        pmcrReads = 0
    }
}

/// `FakePMURegisters` and the `AArch64PMU` state it feeds are both static, and
/// `.serialized` only orders this suite's own tests, not other suites beside it.
/// The run needs `swift test --no-parallel` (see the `test` target in the Makefile).
extension KernelPolicyTestRoot {
@Suite("PMU availability", .serialized)
struct PMUAvailabilityTests {
    @Test("only implemented PMU versions configure counters")
    func versionMatrix() {
        let accepted: [UInt64] = [1, 4, 5, 6, 7, 8, 9]
        let rejected: [UInt64] = [0, 2, 3, 10, 11, 12, 13, 14, 15]

        for version in accepted {
            FakePMURegisters.reset(debugFeatures: version << 8, pmcr: 6 << 11)
            #expect(AArch64PMU.initialize(using: FakePMURegisters.self))
            #expect(FakePMURegisters.configureCalls == 1)
            #expect(FakePMURegisters.pmcrReads == 1)
            #expect(AArch64PMU.probe() == 6)
        }

        for version in rejected {
            FakePMURegisters.reset(debugFeatures: version << 8)
            #expect(!AArch64PMU.initialize(using: FakePMURegisters.self))
            #expect(FakePMURegisters.configureCalls == 0)
            #expect(FakePMURegisters.pmcrReads == 0)
            #expect(AArch64PMU.probe() == 0)
        }
    }

    @Test("supported PMUv3 configures counters")
    func present() {
        FakePMURegisters.reset(debugFeatures: 1 << 8, pmcr: 6 << 11)
        #expect(AArch64PMU.initialize(using: FakePMURegisters.self))
        #expect(FakePMURegisters.configureCalls == 1)
        #expect(FakePMURegisters.pmcrReads == 1)
        #expect(AArch64PMU.probe() == 6)
    }
}


}
