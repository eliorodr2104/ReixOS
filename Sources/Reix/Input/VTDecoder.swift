//
//  VTDecoder.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/08/2026.
//

import ReixABI

/// A bounded VT byte decoder that preserves unconsumed input when its queue is full.
public struct VTDecoder {
    public static let queueCapacity = 16

    private enum EscapeState {
        case idle
        case escape
        case csi
    }

    private struct Checkpoint {
        let queueCount: Int
        let sequence: UInt32
        let escapeState: EscapeState
        let csi: InlineArray<12, UInt8>
        let csiCount: Int
        let pasteActive: Bool
        let pasteCandidate: InlineArray<6, UInt8>
        let pasteCandidateCount: Int
        let utf8: InlineArray<4, UInt8>
        let utf8Count: Int
        let utf8Expected: Int
        let skipNextLF: Bool
    }

    private var queue = InlineArray<16, ReixInputRecord?>(repeating: nil)
    private var queueHead = 0
    private var queueCount = 0
    private var sequence: UInt32 = 1
    private var escapeState: EscapeState = .idle
    private var csi = InlineArray<12, UInt8>(repeating: 0)
    private var csiCount = 0
    private var pasteActive = false
    private var pasteCandidate = InlineArray<6, UInt8>(repeating: 0)
    private var pasteCandidateCount = 0
    private var utf8 = InlineArray<4, UInt8>(repeating: 0)
    private var utf8Count = 0
    private var utf8Expected = 0
    private var skipNextLF = false

    public init() {}

    public var isEmpty: Bool {
        queueCount == 0
    }

    public var isFull: Bool {
        queueCount == Self.queueCapacity
    }

    public mutating func pop() -> ReixInputRecord? {
        guard queueCount > 0 else { return nil }
        let record = queue[queueHead]
        queue[queueHead] = nil
        queueHead = (queueHead + 1) % Self.queueCapacity
        queueCount -= 1
        return record
    }

    @discardableResult
    public mutating func consume(
          _ bytes: UnsafePointer<UInt8>,
          count: Int
    ) -> Int {
        guard count >= 0 else { return 0 }
        var consumed = 0
        while consumed < count {
            let checkpoint = checkpoint()
            guard process(bytes[consumed]) else {
                restore(checkpoint)
                break
            }
            consumed += 1
        }
        return consumed
    }

    @discardableResult
    public mutating func reset() -> Bool {
        let checkpoint = checkpoint()
        if utf8Count > 0 {
            guard emitReplacement() else {
                restore(checkpoint)
                return false
            }
        }
        guard emit(kind: .stateReset) else {
            restore(checkpoint)
            return false
        }
        clearParserState()
        return true
    }

    @discardableResult
    public mutating func finishIdle() -> Bool {
        let checkpoint = checkpoint()
        if utf8Count > 0 {
            guard emitReplacement() else {
                restore(checkpoint)
                return false
            }
            clearUTF8State()
            return true
        }
        if pasteCandidateCount > 0 {
            guard flushPasteCandidate() else {
                restore(checkpoint)
                return false
            }
            return true
        }
        switch escapeState {
            case .idle:
                return true

            case .escape, .csi:
                guard emitKey(.escape) else {
                    restore(checkpoint)
                    return false
                }
                escapeState = .idle
                csiCount = 0
                return true
        }
    }

    private mutating func process(_ byte: UInt8) -> Bool {
        if utf8Count > 0 {
            return processUTF8(
                byte,
                kind: pasteActive ? .pasteChunk : .insert
            )
        }
        if pasteActive {
            return processPaste(byte)
        }
        switch escapeState {
            case .idle:
                if byte == 0x1B {
                    escapeState = .escape
                    return true
                }
                return processText(byte, kind: .insert)

            case .escape:
                guard byte == 0x5B else {
                    guard emitKey(.escape) else { return false }
                    escapeState = .idle
                    return process(byte)
                }
                escapeState = .csi
                csiCount = 0
                return true

            case .csi:
                return processCSI(byte)
        }
    }

    private mutating func processCSI(_ byte: UInt8) -> Bool {
        guard csiCount < csi.count else {
            guard emitKey(.escape) else { return false }
            escapeState = .idle
            return process(byte)
        }
        csi[csiCount] = byte
        csiCount += 1
        guard byte >= 0x40, byte <= 0x7E else { return true }
        let key = csiKey()
        if csiCount == 4,
           csi[0] == 0x32,
           csi[1] == 0x30,
           csi[2] == 0x30,
           csi[3] == 0x7E {
            guard emit(kind: .pasteBegin) else { return false }
            pasteActive = true
        } else if let key {
            guard emitKey(key.key, modifiers: key.modifiers) else { return false }
        } else {
            guard emitKey(.escape) else { return false }
        }
        escapeState = .idle
        csiCount = 0
        return true
    }

    private func csiKey() -> (key: ReixInputKey, modifiers: ReixInputModifiers)? {
        guard csiCount > 0 else { return nil }
        let final = csi[csiCount - 1]
        let separator = separatorIndex()
        let modifiers: ReixInputModifiers
        if let separator {
            guard let code = number(from: separator + 1, to: csiCount - 1),
                  let decoded = modifier(code: code)
            else { return nil }
            modifiers = decoded
        } else {
            modifiers = []
        }
        if final == 0x75, let separator {
            let codepoint = number(from: 0, to: separator)
            if codepoint == 13 { return (.enter, modifiers) }
            if codepoint == 122 && modifiers.contains(.control) {
                return modifiers.contains(.shift) ? (.redo, modifiers) : (.undo, modifiers)
            }
            if codepoint == 121 && modifiers.contains(.control) { return (.redo, modifiers) }
            return nil
        }
        if final == 0x41 || final == 0x42 || final == 0x43 || final == 0x44
            || final == 0x48 || final == 0x46 {
            let parameterEnd = separator ?? csiCount - 1
            let parameter = parameterEnd == 0 ? 1 : number(from: 0, to: parameterEnd)
            guard parameter == 1 else { return nil }
            if final == 0x41 { return (.up, modifiers) }
            if final == 0x42 { return (.down, modifiers) }
            if final == 0x43 { return (.right, modifiers) }
            if final == 0x44 { return (.left, modifiers) }
            if final == 0x48 { return (.home, modifiers) }
            return (.end, modifiers)
        }
        guard final == 0x7E else { return nil }
        let parameterEnd = separator ?? csiCount - 1
        switch number(from: 0, to: parameterEnd) {
            case 1: return (.home, modifiers)
            case 3: return (.delete, modifiers)
            case 4: return (.end, modifiers)
            case 5: return (.pageUp, modifiers)
            case 6: return (.pageDown, modifiers)
            default: return nil
        }
    }

    private func separatorIndex() -> Int? {
        guard csiCount > 1 else { return nil }
        for index in 0..<(csiCount - 1) where csi[index] == 0x3B { return index }
        return nil
    }

    private func number(from start: Int, to end: Int) -> Int? {
        guard start >= 0, start < end, end <= csiCount - 1 else { return nil }
        var result = 0
        for index in start..<end {
            guard csi[index] >= 0x30, csi[index] <= 0x39 else { return nil }
            result = result * 10 + Int(csi[index] - 0x30)
        }
        return result
    }

    private func modifier(code: Int) -> ReixInputModifiers? {
        switch code {
            case 1: return []
            case 2: return [.shift]
            case 3: return [.alt]
            case 4: return [.shift, .alt]
            case 5: return [.control]
            case 6: return [.shift, .control]
            case 7: return [.alt, .control]
            case 8: return [.shift, .alt, .control]
            default: return nil
        }
    }

    private mutating func processPaste(_ byte: UInt8) -> Bool {
        if pasteCandidateCount > 0 {
            if byte == closingByte(at: pasteCandidateCount) {
                pasteCandidate[pasteCandidateCount] = byte
                pasteCandidateCount += 1
                if pasteCandidateCount == 6 {
                    guard emit(kind: .pasteEnd) else { return false }
                    pasteCandidateCount = 0
                    pasteActive = false
                }
                return true
            }
            guard flushPasteCandidate() else { return false }
            return processPaste(byte)
        }
        if byte == closingByte(at: 0) {
            pasteCandidate[0] = byte
            pasteCandidateCount = 1
            return true
        }
        return processText(byte, kind: .pasteChunk)
    }

    private func closingByte(at index: Int) -> UInt8 {
        switch index {
            case 0: return 0x1B
            case 1: return 0x5B
            case 2: return 0x32
            case 3: return 0x30
            case 4: return 0x31
            default: return 0x7E
        }
    }

    private mutating func flushPasteCandidate() -> Bool {
        guard pasteCandidateCount > 0 else { return true }
        for index in 0..<pasteCandidateCount {
            guard processPasteText(pasteCandidate[index]) else { return false }
        }
        pasteCandidateCount = 0
        return true
    }

    private mutating func processText(
          _ byte: UInt8,
          kind: ReixInputKind
    ) -> Bool {
        if pasteActive { return processPasteText(byte) }
        if !pasteActive {
            if byte == 0x03 { return emit(kind: .cancel) }
            if byte == 0x1A { return emitKey(.undo, modifiers: [.control]) }
            if byte == 0x19 { return emitKey(.redo, modifiers: [.control]) }
            if byte == 0x04 { return emit(kind: .eof) }
            if byte == 0x08 || byte == 0x7F { return emitKey(.backspace) }
        }
        if byte == 0x0D {
            guard emit(kind: .enter) else { return false }
            skipNextLF = true
            return true
        }
        if byte == 0x0A {
            if skipNextLF {
                skipNextLF = false
                return true
            }
            return emit(kind: .enter)
        }
        skipNextLF = false
        if !pasteActive, byte == 0x09 {
            return emitKey(.tab)
        }
        if !pasteActive, byte < 0x20 { return emit(kind: .ignored) }
        if byte < 0x80 {
            return emitByte(kind: kind, byte: byte)
        }
        utf8[0] = byte
        utf8Count = 1
        utf8Expected = expectedUTF8Bytes(for: byte)
        if utf8Expected == 0 {
            clearUTF8State()
            return emitReplacement()
        }
        return true
    }

    private mutating func processPasteText(_ byte: UInt8) -> Bool {
        if byte == 0x0D {
            guard emitByte(kind: .pasteChunk, byte: 0x0A) else { return false }
            skipNextLF = true
            return true
        }
        if byte == 0x0A {
            if skipNextLF {
                skipNextLF = false
                return true
            }
            return emitByte(kind: .pasteChunk, byte: byte)
        }
        skipNextLF = false
        if byte == 0x09 { return emitPasteTab() }
        if byte < 0x20 || byte == 0x7F { return emitReplacement() }
        if byte < 0x80 { return emitByte(kind: .pasteChunk, byte: byte) }
        utf8[0] = byte
        utf8Count = 1
        utf8Expected = expectedUTF8Bytes(for: byte)
        if utf8Expected == 0 {
            clearUTF8State()
            return emitReplacement()
        }
        return true
    }

    private mutating func emitPasteTab() -> Bool {
        let bytes = InlineArray<4, UInt8>(repeating: 0x20)
        return bytes.span.withUnsafeBufferPointer {
            guard let record = ReixInputRecord(
                kind: .pasteChunk,
                sequence: sequence,
                bytes: $0.baseAddress,
                count: 4
            ) else { return false }
            return enqueue(record)
        }
    }

    private mutating func processUTF8(
          _ byte: UInt8,
          kind: ReixInputKind
    ) -> Bool {
        guard byte & 0xC0 == 0x80,
              validContinuation(byte)
        else {
            guard emitReplacement() else { return false }
            clearUTF8State()
            return process(byte)
        }
        utf8[utf8Count] = byte
        utf8Count += 1
        guard utf8Count == utf8Expected else { return true }
        if utf8[0] == 0xC2,
           (0x80...0x9F).contains(utf8[1]) {
            guard emitReplacement() else { return false }
            clearUTF8State()
            return true
        }
        guard emitText(kind: kind, bytes: utf8, count: utf8Count) else { return false }
        clearUTF8State()
        return true
    }

    private func expectedUTF8Bytes(for first: UInt8) -> Int {
        switch first {
            case 0xC2...0xDF: return 2
            case 0xE0...0xEF: return 3
            case 0xF0...0xF4: return 4
            default: return 0
        }
    }

    private func validContinuation(_ byte: UInt8) -> Bool {
        guard utf8Count > 0 else { return false }
        if utf8Count != 1 { return true }
        switch utf8[0] {
            case 0xE0: return byte >= 0xA0
            case 0xED: return byte <= 0x9F
            case 0xF0: return byte >= 0x90
            case 0xF4: return byte <= 0x8F
            default: return true
        }
    }

    private mutating func emitReplacement() -> Bool {
        var bytes = InlineArray<4, UInt8>(repeating: 0)
        bytes[0] = 0xEF
        bytes[1] = 0xBF
        bytes[2] = 0xBD
        return emitText(
            kind: pasteActive ? .pasteChunk : .insert,
            bytes: bytes,
            count: 3
        )
    }

    private mutating func emitKey(
        _ key: ReixInputKey,
        modifiers: ReixInputModifiers = []
    ) -> Bool {
        guard let record = ReixInputRecord(
            kind: .key,
            modifiers: modifiers,
            sequence: sequence,
            logicalKey: key,
            physicalKey: syntheticPhysicalKey(for: key)
        ) else { return false }
        return enqueue(record)
    }

    private func syntheticPhysicalKey(for key: ReixInputKey) -> UInt16 {
        // VT keys use high-bit namespace plus their stable logical-key value.
        0x8000 | key.rawValue
    }

    private mutating func emit(kind: ReixInputKind) -> Bool {
        guard let record = ReixInputRecord(
            kind: kind,
            sequence: sequence
        ) else { return false }
        return enqueue(record)
    }

    private mutating func emitByte(
          kind: ReixInputKind,
          byte: UInt8
    ) -> Bool {
        var bytes = InlineArray<4, UInt8>(repeating: 0)
        bytes[0] = byte
        return bytes.span.withUnsafeBufferPointer {
            guard let record = ReixInputRecord(
                kind: kind,
                sequence: sequence,
                bytes: $0.baseAddress,
                count: 1
            ) else { return false }
            return enqueue(record)
        }
    }

    private mutating func emitText(
          kind: ReixInputKind,
          bytes: InlineArray<4, UInt8>,
          count: Int
    ) -> Bool {
        bytes.span.withUnsafeBufferPointer {
            guard let record = ReixInputRecord(
                kind: kind,
                sequence: sequence,
                bytes: $0.baseAddress,
                count: count
            ) else { return false }
            return enqueue(record)
        }
    }

    private mutating func emitText(
          kind: ReixInputKind,
          bytes: InlineArray<6, UInt8>,
          count: Int
    ) -> Bool {
        bytes.span.withUnsafeBufferPointer {
            guard let record = ReixInputRecord(
                kind: kind,
                sequence: sequence,
                bytes: $0.baseAddress,
                count: count
            ) else { return false }
            return enqueue(record)
        }
    }

    private mutating func enqueue(_ record: ReixInputRecord) -> Bool {
        guard queueCount < Self.queueCapacity else { return false }
        let index = (queueHead + queueCount) % Self.queueCapacity
        queue[index] = record
        queueCount += 1
        sequence &+= 1
        if sequence == 0 { sequence = 1 }
        return true
    }

    private mutating func clearParserState() {
        escapeState = .idle
        csiCount = 0
        pasteActive = false
        pasteCandidateCount = 0
        skipNextLF = false
        clearUTF8State()
    }

    private mutating func clearUTF8State() {
        utf8Count = 0
        utf8Expected = 0
    }

    private func checkpoint() -> Checkpoint {
        Checkpoint(
            queueCount: queueCount,
            sequence: sequence,
            escapeState: escapeState,
            csi: csi,
            csiCount: csiCount,
            pasteActive: pasteActive,
            pasteCandidate: pasteCandidate,
            pasteCandidateCount: pasteCandidateCount,
            utf8: utf8,
            utf8Count: utf8Count,
            utf8Expected: utf8Expected,
            skipNextLF: skipNextLF
        )
    }

    private mutating func restore(_ checkpoint: Checkpoint) {
        queueCount = checkpoint.queueCount
        sequence = checkpoint.sequence
        escapeState = checkpoint.escapeState
        csi = checkpoint.csi
        csiCount = checkpoint.csiCount
        pasteActive = checkpoint.pasteActive
        pasteCandidate = checkpoint.pasteCandidate
        pasteCandidateCount = checkpoint.pasteCandidateCount
        utf8 = checkpoint.utf8
        utf8Count = checkpoint.utf8Count
        utf8Expected = checkpoint.utf8Expected
        skipNextLF = checkpoint.skipNextLF
    }
}
