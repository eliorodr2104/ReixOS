//
//  FakePL011.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

public struct FakePL011: Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let framing     = Flags(rawValue: 1 << 0)
        public static let parity      = Flags(rawValue: 1 << 1)
        public static let breakSignal = Flags(rawValue: 1 << 2)
        public static let overrun     = Flags(rawValue: 1 << 3)
    }

    public struct Read: Sendable, Equatable {
        public let byte: UInt8
        public let flags: Flags
        public init(byte: UInt8, flags: Flags) {
            self.byte = byte
            self.flags = flags
        }
    }

    public static let receiveInterrupt: UInt32 = 1 << 4
    public static let transmitInterrupt: UInt32 = 1 << 5
    public static let errorInterrupt: UInt32 = 1 << 9

    public private(set) var imsc: UInt32 = 0
    public private(set) var ris: UInt32 = 0
    public private(set) var rsr: Flags = []
    public private(set) var reads: [Read] = []
    public private(set) var writes: [UInt8] = []
    private var rx: [Read] = []
    private var tx: [UInt8] = []
    private let fifoCapacity: Int
    private let logCapacity: Int

    public init(fifoCapacity: Int = 16, logCapacity: Int = 128) {
        precondition(fifoCapacity > 0 && logCapacity > 0)
        self.fifoCapacity = fifoCapacity
        self.logCapacity = logCapacity
    }

    /// PL011 DR (offset 0x000); the first FIFO value, if any.
    public var dr: Read? { rx.first }
    /// PL011 RSR/ECR (offset 0x004): writing ECR clears all latched errors.
    public var ecr: Flags { rsr }
    public var fr: UInt32 {
        var value: UInt32 = 0
        if rx.isEmpty { value |= 1 << 4 }
        if tx.count == fifoCapacity { value |= 1 << 5 }
        if rx.count == fifoCapacity { value |= 1 << 6 }
        if tx.isEmpty { value |= 1 << 7 }
        return value
    }

    public mutating func injectRX(
        _ byte: UInt8,
        flags : Flags = []
    ) {
        guard rx.count < fifoCapacity else {
            ris |= Self.errorInterrupt
            return
        }
        rx.append(Read(byte: byte, flags: flags))
        ris |= Self.receiveInterrupt
        if !flags.isEmpty { rsr.formUnion(flags); ris |= Self.errorInterrupt }
    }

    @discardableResult
    public mutating func readDR() -> Read? {
        guard !rx.isEmpty else { return nil }
        let value = rx.removeFirst()
        appendRead(value)
        if rx.isEmpty { ris &= ~Self.receiveInterrupt }
        return value
    }

    @discardableResult
    public mutating func writeDR(_ byte: UInt8) -> Bool {
        guard tx.count < fifoCapacity else { return false }
        tx.append(byte)
        appendWrite(byte)
        if tx.count == fifoCapacity { ris &= ~Self.transmitInterrupt }
        return true
    }

    public mutating func drainTX() -> [UInt8] {
        let drained = tx
        tx.removeAll(keepingCapacity: true)
        ris |= Self.transmitInterrupt
        return drained
    }

    public mutating func writeIMSC(_ mask: UInt32) { imsc = mask }
    public mutating func writeECR(_: UInt32) { rsr = [] }
    /// PL011 ICR (offset 0x044) acknowledges raw interrupt sources.
    public mutating func writeICR(_ mask: UInt32) { ris &= ~mask }
    /// PL011 MIS (offset 0x040), calculated from RIS and IMSC.
    public var mis: UInt32 { ris & imsc }
    public var maskedInterruptStatus: UInt32 { mis }

    private mutating func appendRead(_ value: Read) {
        if reads.count == logCapacity { reads.removeFirst() }
        reads.append(value)
    }

    private mutating func appendWrite(_ value: UInt8) {
        if writes.count == logCapacity { writes.removeFirst() }
        writes.append(value)
    }
}
