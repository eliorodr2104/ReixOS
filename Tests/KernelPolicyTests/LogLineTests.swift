//
//  LogLineTests.swift
//  ReixOS
//

import Testing
@testable import Kernel

extension KernelPolicyTestRoot {
@Suite("Kernel log line endings")
struct LogLineTests {

    @Test("trailer appends a newline by default")
    func defaultNewline() {
        var output: [UInt8] = []

        LogLine.trailer(closing: false) { output.append($0) }

        #expect(output == [10])
    }

    @Test("trailer can omit its newline")
    func omittedNewline() {
        var output: [UInt8] = []

        LogLine.trailer(closing: false, newline: false) { output.append($0) }

        #expect(output.isEmpty)
    }
}
}
