import Testing
import TerminalTestSupport

struct TerminalScreenOracleTests {
    @Test func fakePL011TracksFIFOErrorsAndAcknowledgements() {
        var uart = FakePL011(fifoCapacity: 2, logCapacity: 2)
        uart.writeIMSC(FakePL011.receiveInterrupt | FakePL011.errorInterrupt)
        uart.injectRX(65, flags: [.parity])
        uart.injectRX(66)
        uart.injectRX(67)
        #expect(uart.maskedInterruptStatus == FakePL011.receiveInterrupt | FakePL011.errorInterrupt)
        #expect(uart.readDR() == .init(byte: 65, flags: [.parity]))
        uart.writeICR(FakePL011.errorInterrupt)
        #expect(uart.maskedInterruptStatus == FakePL011.receiveInterrupt)
        #expect(uart.writeDR(1) && uart.writeDR(2) && !uart.writeDR(3))
        #expect(uart.drainTX() == [1, 2])
        #expect(uart.rsr.contains(.parity))
        uart.writeECR(0)
        #expect(uart.rsr.isEmpty)
    }

    @Test func screenHandlesCursorClearCRLFAndSGR() throws {
        var screen = TerminalScreenModel(columns: 5, rows: 3)
        try screen.feed("ab\rZ\n\u{1B}[1;2H\u{1B}[1mX\u{1B}[0m\u{1B}[K")
        #expect(screen.line(0) == "ZX   ")
        #expect(screen.line(1) == "     ")
        #expect(screen.cells[1].attributes.bold)
        #expect(throws: TerminalScreenModel.Error.self) { try screen.feed("\u{1B}[31m") }
    }

    @Test func clockOnlyAdvancesWhenRequested() {
        var clock = DeterministicClock()
        #expect(clock.ticks == 0)
        clock.advance(by: 7)
        #expect(clock.ticks == 7)
        clock.advance(by: UInt64.max)
        #expect(clock.ticks == UInt64.max)
    }

    @Test func oracleDistinguishesCorrectAndMutatedReplay() throws {
        var correct = TerminalScreenModel(columns: 20, rows: 4)
        var mutated = TerminalScreenModel(columns: 20, rows: 4)
        try correct.feed("reix> first\r\nreix> second")
        try mutated.feed("reix> first\nreix> second")
        #expect(correct.line(1) == "reix> second        ")
        #expect(correct.line(1) != mutated.line(1))
    }

    @Test func oracleCoversPasteWrapResizeAndShortening() throws {
        for width in [20, 80, 240] {
            var screen = TerminalScreenModel(columns: width, rows: 12)
            try screen.feed("reix> " + String(repeating: "x", count: width * 2) + "\r\nreix> ok")
            #expect(screen.line(screen.cursorRow).hasPrefix("reix> ok"))
        }
        var screen = TerminalScreenModel(columns: 20, rows: 4)
        try screen.feed("reix> 1234567890\u{1B}[2K\rreix> x")
        #expect(screen.line(0).hasPrefix("reix> x"))
        #expect(!screen.line(0).contains("9"))
    }

    @Test func incrementalEscapeResizeAndCursorRelativeMoves() throws {
        var screen = TerminalScreenModel(columns: 5, rows: 2)
        try screen.feed("abc\u{1B}[")
        try screen.feed("2D!")
        #expect(screen.line(0) == "a!c  ")
        screen.resize(columns: 8, rows: 3)
        try screen.feed("\u{1B}[2B\u{1B}[3CZ")
        #expect(screen.cursorRow == 2 && screen.cursorColumn == 6)
    }

    @Test func pasteReplaysCRLFVariantsAndTruncationSeparately() throws {
        for paste in ["a", "a\r\nb", "a\nb\rc\r\nd\ne\rf\r\ng\nh\ri\r\nj"] {
            var screen = TerminalScreenModel(columns: 20, rows: 12)
            try screen.feed(paste)
            try screen.finish()
        }
        var truncated = TerminalScreenModel(columns: 20, rows: 2)
        try truncated.feed("paste\u{1B}[")
        #expect(throws: TerminalScreenModel.Error.self) { try truncated.finish() }
    }
}
//
//  TerminalScreenOracleTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//
