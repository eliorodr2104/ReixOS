//
//  BuildPipelineTests.swift
//  ReixOS
//

import Testing
import Foundation
@testable import ReixBuild

@Suite struct BuildPipelineTests {

    @Test func countsModulesAndNotTheTasksThatShareTheCounter() {
        #expect(BuildPipeline.compiling("Compiling BlockServer BlockServer.swift") == "BlockServer")
        #expect(BuildPipeline.compiling("Emitting module ReixFS")               == nil)
        #expect(BuildPipeline.compiling("Archiving libKernel.a")                == nil)
        #expect(BuildPipeline.compiling("Wrapping AST for Kernel for debugging") == nil)
        #expect(BuildPipeline.compiling("Write swift-version-43AF9A9ED32E53B.txt") == nil)
    }

    @Test func aConflictCopyIsASpaceThenDigitsAndNothingElse() {
        #expect(BuildPipeline.isConflictCopy("debug 2.yaml"))
        #expect(BuildPipeline.isConflictCopy("plugins 2"))
        #expect(BuildPipeline.isConflictCopy("ReixKernel 2.build"))
        #expect(!BuildPipeline.isConflictCopy("Top2.elf"))
        #expect(!BuildPipeline.isConflictCopy("Init.elf"))
        #expect(!BuildPipeline.isConflictCopy("AArch64PMU.gen.S"))
    }

    /// The scratch tree is named by the boot mode unless something names it,
    /// which is what keeps one mode from relinking another mode's objects.
    @Test func theBootModeNamesTheScratchTree() {
        #expect(BuildPipeline.Options(bootMode: "diagnostic").buildPath == ".build-freestanding-diagnostic")
        #expect(BuildPipeline.Options(bootMode: "standard", buildPath: ".build-terminal-profile").buildPath
                == ".build-terminal-profile")
    }
}
