//
//  DiskModule.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

public enum DiskModule: ShellModule {
    public static let receiver: StaticString = "disk"

    public static func handle(
        _ command   : Command,
          in session: inout ShellSession
    ) -> ShellOutcome {
        handleResult(command, in: &session).outcome
    }

    public static func handleResult(
        _ command   : Command,
          in session: inout ShellSession
    ) -> ShellCommandResult {
        var records = ShellResult()
        let isInfo  = session.spells(command.verb, "info")
        let isRead  = session.spells(command.verb, "read")
        guard isInfo || isRead else { return ShellCommandResult(outcome: .notHandled, records: records) }
        let arity = isInfo ? Verbs.diskInfo : Verbs.diskRead
        guard arity.accepts(command.argumentCount) else {
            _ = records.appendPresentation("  ")
            _ = records.appendPresentation(arity.usage)
            _ = records.appendPresentation("\n")
            return ShellCommandResult(outcome: .handled, status: .refused, records: records)
        }
        guard var disk = Disk.attached(session.environment) else {
            _ = records.appendPresentation("this shell was given no view of the disk\n")
            return ShellCommandResult(outcome: .handled, status: .unavailable, records: records)
        }
        if isInfo {
            _ = records.appendBlockGeometry(sectors: disk.sectorCount, sectorSize: disk.sectorSize, maximumRun: disk.maximumRun)
            return ShellCommandResult(outcome: .handled, records: records)
        }
        guard let sector = decimal(command.arguments[0], session) else {
            _ = records.appendPresentation("  disk.read takes one sector number, as in disk.read(0)\n")
            return ShellCommandResult(outcome: .handled, status: .refused, records: records)
        }
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { buffer in
            let status = disk.read(sector: sector, into: UnsafeMutableRawPointer(buffer.baseAddress!))
            if status == .ok {
                _ = records.appendBlockRead(sector: sector, bytes: buffer.baseAddress!, count: 64)
            } else {
                _ = records.appendBlockStatus(status.rawValue)
            }
        }
        return ShellCommandResult(outcome: .handled, records: records)
    }

    public static func describe() {}


    private enum Disk {
        nonisolated(unsafe) static var client: BlockClient? = nil
        nonisolated(unsafe) static var looked = false

        static func attached(_ environment: Environment) -> BlockClient? {
            guard !looked else { return client }
            looked = true
            guard let endpoint = environment.block else { return nil }
            client = BlockClient(block: endpoint)
            return client
        }
    }
}

func decimal(
    _ span   : Span,
    _ session: ShellSession
) -> UInt64? {
    guard let text = session.bytes(of: span), text.count > 0, text.count <= 20 else { return nil }
    var value: UInt64 = 0
    for offset in 0..<text.count {
        let digit = text.bytes[offset]
        guard digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "9") else { return nil }
        let (shifted, tooBig) = value.multipliedReportingOverflow(by: 10)
        guard !tooBig else { return nil }
        let (sum, carried) = shifted.addingReportingOverflow(UInt64(digit - UInt8(ascii: "0")))
        guard !carried else { return nil }
        value = sum
    }
    return value
}
