//
//  TerminalScreenModel.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

public struct TerminalScreenModel: Sendable {
    public enum Error: Swift.Error, Equatable { case unsupportedSequence([UInt8]); case invalidUTF8 }
    public struct Attributes: Equatable, Sendable { public var bold = false; public var inverse = false; public init() {} }
    public struct Cell: Equatable, Sendable {
        public var character: Character
        public var attributes: Attributes
        public init(character: Character = " ", attributes: Attributes = Attributes()) {
            self.character = character
            self.attributes = attributes
        }
    }

    public private(set) var columns: Int
    public private(set) var rows: Int
    public private(set) var cursorColumn = 0
    public private(set) var cursorRow = 0
    public private(set) var cells: [Cell]
    private var attributes = Attributes()
    private var escape: [UInt8] = []

    public init(columns: Int, rows: Int) {
        precondition(columns > 0 && rows > 0)
        self.columns = columns
        self.rows = rows
        self.cells = Array(repeating: Cell(), count: columns * rows)
    }

    public mutating func feed(_ text: String) throws { try feed(Array(text.utf8)) }
    public mutating func feed(_ bytes: [UInt8]) throws {
        for byte in bytes { try consume(byte) }
    }

    public mutating func finish() throws {
        if !escape.isEmpty { defer { escape.removeAll(keepingCapacity: true) }; throw Error.unsupportedSequence(escape) }
    }

    public mutating func resize(
        columns: Int,
        rows   : Int
    ) {
        precondition(columns > 0 && rows > 0)
        var replacement = Array(repeating: Cell(), count: columns * rows)
        for row in 0..<min(self.rows, rows) {
            for column in 0..<min(self.columns, columns) {
                replacement[row * columns + column] = cells[row * self.columns + column]
            }
        }
        self.columns = columns
        self.rows = rows
        cells = replacement
        cursorColumn = min(cursorColumn, columns - 1)
        cursorRow = min(cursorRow, rows - 1)
    }

    public func line(_ row: Int) -> String {
        String(cells[(row * columns)..<((row + 1) * columns)].map(\.character))
    }

    private mutating func consume(_ byte: UInt8) throws {
        if !escape.isEmpty {
            escape.append(byte)
            if escape.count == 2 && byte != 0x5B { throw Error.unsupportedSequence(escape) }
            if escape.count > 2 && byte >= 0x40 && byte <= 0x7E { try finishEscape() }
            return
        }
        switch byte {
            case 0x1B: escape = [byte]
            case 0x0D: cursorColumn = 0
            case 0x0A: lineFeed()
            case 0x08: cursorColumn = max(0, cursorColumn - 1)
            case 0x20...0x7E: put(Character(UnicodeScalar(byte)))
            default: throw Error.unsupportedSequence([byte])
        }
    }

    private mutating func finishEscape() throws {
        defer { escape.removeAll(keepingCapacity: true) }
        let final      = escape.last!
        let parameters = String(decoding: Array(escape.dropFirst(2).dropLast()), as: UTF8.self)
        let values     = parameters.isEmpty ? [0] : parameters.split(separator: ";").map { Int($0) ?? -1 }
        switch final {
            case 0x48, 0x66: // CUP
                guard values.count <= 2, !values.contains(-1) else { throw Error.unsupportedSequence(escape) }
                cursorRow = min(rows - 1, max(0, (values.first ?? 1) - 1))
                cursorColumn = min(columns - 1, max(0, (values.dropFirst().first ?? 1) - 1))
            case 0x41, 0x42, 0x43, 0x44: // CUU/CUD/CUF/CUB
                guard values.count == 1, let amount = values.first, amount >= 0 else { throw Error.unsupportedSequence(escape) }
                let distance = max(1, amount)
                if final == 0x41 { cursorRow = max(0, cursorRow - distance) }
                if final == 0x42 { cursorRow = min(rows - 1, cursorRow + distance) }
                if final == 0x43 { cursorColumn = min(columns - 1, cursorColumn + distance) }
                if final == 0x44 { cursorColumn = max(0, cursorColumn - distance) }
            case 0x4A: // ED
                guard values == [0] || values == [2] else { throw Error.unsupportedSequence(escape) }
                if values == [2] { clearAll(); cursorColumn = 0; cursorRow = 0 } else { clearToEnd() }
            case 0x4B: // EL
                guard values == [0] || values == [2] else { throw Error.unsupportedSequence(escape) }
                if values == [2] { clearRow(cursorRow) } else { clearToLineEnd() }
            case 0x6D: // SGR: reset, bold and inverse only
                for value in values {
                    switch value { case 0: attributes = Attributes(); case 1: attributes.bold = true; case 7: attributes.inverse = true; default: throw Error.unsupportedSequence(escape) }
                }
            default: throw Error.unsupportedSequence(escape)
        }
    }

    private mutating func put(_ character: Character) {
        cells[cursorRow * columns + cursorColumn] = Cell(character: character, attributes: attributes)
        cursorColumn += 1
        if cursorColumn == columns { cursorColumn = 0; lineFeed() }
    }
    private mutating func lineFeed() { if cursorRow + 1 == rows { cells.removeFirst(columns); cells.append(contentsOf: repeatElement(Cell(), count: columns)) } else { cursorRow += 1 } }
    private mutating func clearAll() { cells = Array(repeating: Cell(), count: cells.count) }
    private mutating func clearRow(_ row: Int) { for index in 0..<columns { cells[row * columns + index] = Cell() } }
    private mutating func clearToEnd() { for index in (cursorRow * columns + cursorColumn)..<cells.count { cells[index] = Cell() } }
    private mutating func clearToLineEnd() { for index in cursorColumn..<columns { cells[cursorRow * columns + index] = Cell() } }
}
