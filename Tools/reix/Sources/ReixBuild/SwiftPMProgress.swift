//
//  SwiftPMProgress.swift
//  ReixOS
//

import Foundation

/// `[61/75] Compiling BlockServer BlockServer.swift`, read back as numbers.
///
/// The only parser in the build, because it is the only output the build does
/// not write itself. Everything else the CLI invokes, and therefore counts.
public struct SwiftPMProgress {

    public struct Update: Equatable, Sendable {
        public let done  : Int
        public let total : Int
        public let detail: String

        public init(done: Int, total: Int, detail: String) {
            self.done = done; self.total = total; self.detail = detail
        }
    }

    public static func parse(_ line: String) -> Update? {
        guard line.hasPrefix("["),
              let close = line.firstIndex(of: "]"),
              let slash = line[line.startIndex..<close].firstIndex(of: "/")
        else { return nil }

        let doneText  = line[line.index(after: line.startIndex)..<slash]
        let totalText = line[line.index(after: slash)..<close]

        guard let done = Int(doneText), let total = Int(totalText), total > 0 else { return nil }

        let detail = line[line.index(after: close)...]
            .trimmingCharacters(in: .whitespaces)

        return Update(done: done, total: total, detail: detail)
    }
}

/// What the compile phase should be showing right now.
///
/// Holds the last understood count so a run of unrecognised lines does not blank
/// the bar, and gives up on it after `stallAfter` rather than leave a number on
/// screen that stopped being true. It degrades; it does not lie.
public struct ProgressTracker {

    public enum State: Equatable, Sendable {
        case bar(done: Int, total: Int, detail: String)
        case spinner(lastLine: String)
    }

    private let stallAfter    : Duration
    private var last          : SwiftPMProgress.Update?
    private var lastUnderstood: ContinuousClock.Instant?

    public init(stallAfter: Duration = .seconds(5)) { self.stallAfter = stallAfter }

    public mutating func ingest(_ line: String, at now: ContinuousClock.Instant) -> State {
        if let update = SwiftPMProgress.parse(line) {
            last           = update
            lastUnderstood = now
            return .bar(done: update.done, total: update.total, detail: update.detail)
        }

        guard let last, let since = lastUnderstood, now - since < stallAfter else {
            return .spinner(lastLine: line)
        }
        return .bar(done: last.done, total: last.total, detail: last.detail)
    }
}
