//
//  UstarWriterTests.swift
//  ReixOS
//

import Testing
import Foundation
@testable import ReixBuild

/// The byte-identity gate for the whole port rests on this archive being a pure
/// function of its members. These pin that, so a later refactor cannot quietly
/// introduce a timestamp and take the gate down with it.
@Suite struct UstarWriterTests {

    @Test func archiveIsDeterministic() {
        let members = [
            UstarWriter.Member(name: "Init.elf",  data: Data(repeating: 0xAB, count: 5000)),
            UstarWriter.Member(name: "Shell.elf", data: Data(repeating: 0xCD, count: 17)),
        ]
        #expect(UstarWriter.write(members: members) == UstarWriter.write(members: members))
    }

    @Test func memberDataIsPageAligned() {
        let members = [
            UstarWriter.Member(name: "Init.elf",  data: Data(repeating: 0xAB, count: 5000)),
            UstarWriter.Member(name: "Shell.elf", data: Data(repeating: 0xCD, count: 17)),
        ]
        #expect(UstarWriter.verifyPageAlignment(UstarWriter.write(members: members)))
    }

    @Test func headerCarriesNoClock() {
        let archive = UstarWriter.write(members: [
            UstarWriter.Member(name: "Init.elf", data: Data([0x7F, 0x45, 0x4C, 0x46])),
        ])
        // ustar mtime lives at offset 136, width 12, octal ASCII: the writer
        // emits 11 zero-padded digits and a NUL, so a clock would show as digits.
        let mtime = String(decoding: archive[136..<148], as: UTF8.self)
        #expect(mtime.trimmingCharacters(in: CharacterSet(charactersIn: " \0")) == "00000000000")
    }
}
