//
//  Unicode16ConformanceTests.swift
//  ReixOS
//

import Foundation
import Testing
import ReixABI

@Suite("Unicode 16 generated terminal tables")
struct Unicode16ConformanceTests {
    @Test("all official extended grapheme break vectors agree in both directions")
    func graphemeBreakCorpus() throws {
        let corpus = try fixture("GraphemeBreakTest")
        var vector = 0
        for raw in corpus.split(whereSeparator: \Character.isNewline) {
            let body = raw.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )[0]
                .trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            vector += 1
            var bytes: [UInt8] = []
            var expected: [Int] = []
            for token in body.split(whereSeparator: \Character.isWhitespace) {
                if token.unicodeScalars.count == 1,
                   token.unicodeScalars.first?.value == 0x00F7 {
                    expected.append(bytes.count)
                } else if token.unicodeScalars.first?.value != 0x00D7,
                          let value = UInt32(token, radix: 16),
                          let scalar = UnicodeScalar(value) {
                    bytes.append(contentsOf: String(scalar).utf8)
                }
            }
            let actual = boundaries(in: bytes)
            if actual != expected {
                Issue.record("GraphemeBreakTest vector \(vector): expected \(expected), found \(actual)")
                return
            }
            var reverse: [Int] = [bytes.count]
            var cursor = bytes.count
            while cursor > 0 {
                guard let previous = bytes.withUnsafeBufferPointer({ buffer in
                    ReixTextLayout.previousGraphemeBoundary(
                        before: cursor,
                        count: buffer.count,
                        byte: { buffer[$0] }
                    )
                }) else {
                    Issue.record("GraphemeBreakTest vector \(vector): reverse traversal stopped at \(cursor)")
                    return
                }
                reverse.append(previous)
                cursor = previous
            }
            if reverse.reversed() != expected {
                Issue.record("GraphemeBreakTest vector \(vector): reverse boundaries disagree")
                return
            }
            let boundarySet = Set(expected)
            for offset in 0...bytes.count {
                let classified = bytes.withUnsafeBufferPointer { buffer in
                    ReixTextLayout.isGraphemeBoundary(offset, count: buffer.count) { buffer[$0] }
                }
                if classified != boundarySet.contains(offset) {
                    Issue.record("GraphemeBreakTest vector \(vector): byte \(offset) boundary mismatch")
                    return
                }
            }
        }
        #expect(vector > 1_000)
    }

    @Test("every Unicode 16 W F and Extended Pictographic scalar is two cells")
    func exhaustiveWideProperties() throws {
        try checkEveryScalar(
            in: fixture("EastAsianWidth"),
            properties: ["W", "F"]
        )
        try checkEveryScalar(
            in: fixture("emoji-data"),
            properties: ["Extended_Pictographic"]
        )
    }

    @Test("invalid and split UTF-8 is refused without a partial boundary")
    func malformedUTF8() {
        let malformed: [[UInt8]] = [
            [0x80],
            [0xC0, 0x80],
            [0xE2, 0x82],
            [0xED, 0xA0, 0x80],
            [0xF4, 0x90, 0x80, 0x80],
            [0xF0, 0x9F, 0x92],
        ]
        for bytes in malformed {
            let valid = bytes.withUnsafeBufferPointer { buffer in
                ReixTextLayout.validUTF8(count: buffer.count) { buffer[$0] }
            }
            #expect(!valid)
        }
        let euro = Array("€".utf8)
        for available in 0..<euro.count {
            let valid = ReixTextLayout.validUTF8(count: euro.count) { index in
                index < available ? euro[index] : nil
            }
            #expect(!valid)
        }
    }

    private func boundaries(in bytes: [UInt8]) -> [Int] {
        bytes.withUnsafeBufferPointer { buffer in
            var result = [0]
            var cursor = 0
            while cursor < buffer.count {
                guard let next = ReixTextLayout.nextGraphemeBoundary(
                    after: cursor,
                    count: buffer.count,
                    byte: { buffer[$0] }
                ) else { return [] }
                result.append(next)
                cursor = next
            }
            return result
        }
    }

    private func checkEveryScalar(
        in contents: String,
        properties: Set<String>
    ) throws {
        var checked = 0
        for raw in contents.split(whereSeparator: \Character.isNewline) {
            let body = raw.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )[0]
            let fields = body.split(separator: ";", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            let property = fields[1].trimmingCharacters(in: .whitespaces)
            guard properties.contains(property) else { continue }
            let bounds = fields[0].trimmingCharacters(in: .whitespaces).split(separator: ".")
            guard !bounds.isEmpty,
                  let start = UInt32(bounds[0], radix: 16),
                  let end = UInt32(bounds.count > 1 ? bounds[bounds.count - 1] : bounds[0], radix: 16)
            else { continue }
            for value in start...end {
                guard let scalar = UnicodeScalar(value) else { continue }
                let bytes = Array(String(scalar).utf8)
                let width = bytes.withUnsafeBufferPointer { buffer in
                    ReixTextLayout.cellWidth(
                        from: 0,
                        to: buffer.count,
                        count: buffer.count,
                        byte: { buffer[$0] }
                    )
                }
                if width != 2 {
                    Issue.record("U+\(String(value, radix: 16, uppercase: true)) in \(property) has width \(String(describing: width))")
                    return
                }
                checked += 1
            }
        }
        #expect(checked > 0)
    }

    private func fixture(_ name: String) throws -> String {
        let nested = Bundle.module.url(
            forResource: name,
            withExtension: "txt",
            subdirectory: "Fixtures"
        )
        let flat = Bundle.module.url(forResource: name, withExtension: "txt")
        let url = try #require(nested ?? flat)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
