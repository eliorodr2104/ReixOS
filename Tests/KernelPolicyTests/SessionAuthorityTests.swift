//
//  SessionAuthorityTests.swift
//  ReixOS
//

import Foundation
import Testing
import ReixABI

extension KernelPolicyTestRoot {
@Suite("Session authority policy")
struct SessionAuthorityTests {

    @Test("the shell filesystem view cannot unmount the volume")
    func shellViewExcludesUnmount() {
        let rights = FSRights.everything.subtracting(.unmount)

        #expect(!rights.contains(.unmount))
        #expect(rights.contains(.lookup))
        #expect(rights.contains(.read))
        #expect(rights.contains(.write))
        #expect(rights.contains(.delegate))
    }

    @Test("Init keeps diagnostic and shutdown authority through spawn commit")
    func initOwnsTheCommit() throws {
        let root       = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let initSource = try String(
            contentsOf: root.appending(path: "Sources/Userland/Init/Init.swift"),
            encoding: .utf8
        )
        let shellSource = try String(
            contentsOf: root.appending(path: "Sources/Userland/Shell/Modules/CoreModule.swift"),
            encoding: .utf8
        )

        let spawn = try #require(initSource.range(of: "let processServer = programs.map"))
        let drop  = try #require(
            initSource.range(of: "if let diagnostic { _ = capDrop(diagnostic) }")
        )
        #expect(spawn.lowerBound < drop.lowerBound)

        let processServerGrantBlock = String(initSource[spawn.lowerBound..<drop.lowerBound])
        #expect(processServerGrantBlock.contains("source: diagnostic"))
        #expect(processServerGrantBlock.contains("BootCap.sessionControl.rawValue"))
        #expect(!processServerGrantBlock.contains("source: BootCap.power.rawValue"))
        #expect(initSource.contains(".everything.subtracting(.unmount)"))
        #expect(initSource.contains("files.bind(files.root, rights:"))
        #expect(initSource.contains("let launched = launchProgram("))
        #expect(initSource.contains("superviseSession("))

        #expect(shellSource.contains("SessionControlOperation.shutdown.request"))
        #expect(shellSource.contains("environment.sessionControl"))
        #expect(!shellSource.contains("environment.parentEndpoint"))
        #expect(!shellSource.contains("files.unmount()"))
        #expect(!shellSource.contains("powerOff("))
    }
}
}
