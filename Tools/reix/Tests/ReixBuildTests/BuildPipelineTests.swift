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

    /// The scratch tree is named by the boot mode unless something names it,
    /// which is what keeps one mode from relinking another mode's objects.
    @Test func theBootModeNamesTheScratchTree() {
        #expect(BuildPipeline.Options(bootMode: "diagnostic").buildPath == ".build-freestanding-diagnostic")
        #expect(BuildPipeline.Options(bootMode: "standard", buildPath: ".build-terminal-profile").buildPath
                == ".build-terminal-profile")
    }
}
