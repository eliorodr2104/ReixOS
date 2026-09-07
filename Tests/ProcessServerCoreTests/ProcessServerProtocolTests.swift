//
//  ProcessServerProtocolTests.swift
//  ReixOS
//

import Testing
import ReixABI
import ProcessServerCore

@Suite("ProcessServer wire protocol")
struct ProcessServerProtocolTests {

    @Test("launch basenames round trip without carrying a pathname")
    func launchNameRoundTrip() {
        let name    : StaticString = "Shell.elf"
        let message = ProcessLaunchRequest.message(
            name  : name.utf8Start,
            length: name.utf8CodeUnitCount
        )

        #expect(message != nil)
        guard let message,
              let decoded = ProcessLaunchRequest.name(from: message)
        else { return }

        #expect(decoded.length == name.utf8CodeUnitCount)
        for index in 0..<decoded.length {
            #expect(decoded.bytes[index] == name.utf8Start[index])
        }
    }

    @Test("launch requests are bounded and reject empty names")
    func launchNameBounds() {
        let empty  : StaticString = ""
        let tooLong: StaticString = "0123456789abc"

        #expect(ProcessLaunchRequest.message(
            name: empty.utf8Start,
            length: empty.utf8CodeUnitCount
        ) == nil)
        #expect(ProcessLaunchRequest.message(
            name: tooLong.utf8Start,
            length: tooLong.utf8CodeUnitCount
        ) == nil)
    }

    @Test("environment transaction carries version count index and nonce")
    func environmentTransactionShape() {
        let begin = EnvironmentTransaction.begin(count: 3, nonce: 0xA5)
        #expect(begin.tag.label == EnvironmentTransactionOperation.begin.rawValue)
        #expect(begin.tag.length == 3)
        #expect(begin.words[0] == EnvironmentTransaction.version)
        #expect(begin.words[1] == 3)
        #expect(begin.words[2] == 0xA5)

        let item = EnvironmentTransaction.binding(
            .programs,
            index: 2,
            nonce: 0xA5
        )
        #expect(item.tag.label == EnvironmentTransactionOperation.binding.rawValue)
        #expect(item.words[0] == EnvironmentBinding.programs.rawValue)
        #expect(item.words[1] == 2)
        #expect(item.words[2] == 0xA5)

        #expect(EnvironmentBinding.programs.rawValue == BootCap.programs.rawValue)
        #expect(EnvironmentBinding.processServer.rawValue == BootCap.processServer.rawValue)
        #expect(EnvironmentBinding.sessionControl.rawValue == BootCap.sessionControl.rawValue)
        #expect(EnvironmentBinding.profileMarker.rawValue == BootCap.profileMarker.rawValue)
    }

    @Test("launch profiles are exact and declare every required authority")
    func launchProfiles() {
        let shellName  : StaticString = "Shell.elf"
        var shellBytes = InlineArray<12, UInt8>(repeating: 0)
        for index in 0..<shellName.utf8CodeUnitCount {
            shellBytes[index] = shellName.utf8Start[index]
        }

        let shell = ProgramProfile.identify(
            shellBytes,
            length: shellName.utf8CodeUnitCount
        )
        #expect(shell == .shell)

        let required = shell?.bindings
        #expect(required?.count == 10)
        for binding in [
            EnvironmentBinding.terminal,
            .inputConsumer,
            .container,
            .block,
            .programs,
            .processServer,
            .sessionControl,
        ] {
            var found = false
            if let required {
                for index in 0..<required.count where required.storage[index]?.binding == binding {
                    found = true
                }
            }
            #expect(found)
        }

        let unknownName : StaticString = "Other.elf"
        var unknown     = InlineArray<12, UInt8>(repeating: 0)
        for index in 0..<unknownName.utf8CodeUnitCount {
            unknown[index] = unknownName.utf8Start[index]
        }
        #expect(ProgramProfile.identify(
            unknown,
            length: unknownName.utf8CodeUnitCount
        ) == nil)
    }
}
