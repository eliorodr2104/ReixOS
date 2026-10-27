//
//  BuildState.swift
//  ReixOS
//

import Foundation
import ReixBuild

/// What the last build measured, so this one can say what moved.
///
/// One small file, no version field and no migration: a record this build
/// cannot decode is a record this build ignores, and the panel then shows the
/// sizes with no delta, which is what a first build shows anyway.
struct BuildRecord: Codable {
    /// Boot mode and configuration. A diagnostic kernel is a quarter of a
    /// megabyte heavier than a standard one, so comparing across modes would
    /// report a change nobody made.
    var mode   : String
    var kernel : Int
    var initrd : Int
    var elapsed: Double
    var phases : [String: Double]

    static func url(at root: URL) -> URL {
        root.appending(path: ".reix/last-build.json")
    }

    static func read(at root: URL) -> BuildRecord? {
        guard let data = try? Data(contentsOf: url(at: root)) else { return nil }
        return try? JSONDecoder().decode(BuildRecord.self, from: data)
    }

    func write(at root: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url(at: root))
    }
}


/// What the dashboard draws, folded out of the event stream.
///
/// The view reads this and nothing else. The pipeline writes events and knows
/// nothing about it, which is why the same build drives the flat renderer with
/// no branch anywhere in the pipeline.
///
/// `@Observable` rather than the `ObservableObject` the plan named: SwiftTUI
/// tracks reads through Observation and has no Combine subscription to make.
@MainActor @Observable
final class BuildState {

    enum Status: Equatable {
        case waiting
        case running(done: Int, total: Int, now: String)
        case finished(String, Duration)
        case skipped(String)
        case failed
    }

    /// One instance, reached by name from the view body. `App` demands a
    /// `nonisolated init()`, so a scene cannot be handed its state as an
    /// argument and something has to carry it across.
    static let shared = BuildState()

    var status: [Phase: Status] = [:]
    var phases: [Phase]         = []

    /// What a phase said it was about to do. The sub-row shows it until the
    /// first progress event names something more specific, so a phase that
    /// reports no progress at all still says what it is doing.
    var why: [Phase: String] = [:]

    /// The last lines the tools wrote, oldest first. Bounded: a cold build
    /// writes thousands and the panel can only ever show a screenful, so an
    /// unbounded transcript would be memory nobody reads. The log keeps it all.
    private(set) var output: [String] = []
    private static let tailDepth = 200

    /// How long the phase that is running has been running, and how long the
    /// build has. A clock nobody advances reads as a build that stopped, so
    /// the view ticks both.
    var live : Duration = .zero
    var total: Duration = .zero

    /// The two artifacts the bottom band weighs, stat'ed once the phase that
    /// writes them ends. Nil before that, and on the first build ever, which
    /// is why the band shows a size with no delta rather than a delta of zero.
    var kernelBytes: Int?
    var initrdBytes: Int?
    var previous   : BuildRecord?

    /// Read after the screen is gone, never drawn: the output of the tool that
    /// failed, the phase it failed in, and whether the build succeeded.
    private(set) var failure     : String?
    private(set) var failedPhase : Phase?
    private(set) var ok = false

    @ObservationIgnored var steps   : [PhaseRunner.Step] = []
    @ObservationIgnored var mode    = ""
    @ObservationIgnored var version = ""
    @ObservationIgnored var root    = URL(fileURLWithPath: ".")

    private var began   = ContinuousClock.now
    private var opened  = ContinuousClock.now
    private var elapsed: [Phase: Duration] = [:]

    /// Only the phases this invocation will actually run. A row for a phase
    /// that can never start is a row that reads as stuck forever.
    /// `mode` must already be set: the record it loads is only the one this
    /// same configuration wrote.
    func start(_ steps: [PhaseRunner.Step], root: URL) {
        self.steps = steps
        self.root  = root
        phases     = steps.map(\.phase)
        status     = Dictionary(uniqueKeysWithValues: phases.map { ($0, .waiting) })
        previous   = BuildRecord.read(at: root).flatMap { $0.mode == mode ? $0 : nil }
        opened     = ContinuousClock.now

        // What is on the disk right now, which until the image phase rewrites
        // them is the previous build's pair. A weighing, not a promise.
        weighArtifacts()
    }

    func apply(_ event: BuildEvent) {
        switch event {
            case .began(let phase, let reason):
                why[phase]    = reason
                status[phase] = .running(done: 0, total: 0, now: "")
                began         = ContinuousClock.now
                live          = .zero

            case .progress(let phase, let done, let total, let now):
                status[phase] = .running(done: done, total: total, now: now)

            case .output(_, let line):
                // A terminal acts on a control byte instead of showing it, which
                // would tear the panel. Filtered here, not on every redraw.
                output.append(String(line.unicodeScalars.filter { $0.value >= 0x20 }))
                if output.count > Self.tailDepth {
                    output.removeFirst(output.count - Self.tailDepth)
                }

            case .ended(let phase, let summary, let duration):
                status[phase]  = .finished(summary, duration)
                elapsed[phase] = duration
                if phase == .image { weighArtifacts() }

            case .skipped(let phase, let because):
                status[phase] = .skipped(because)

            case .failed(let phase, _):
                status[phase] = .failed
                failedPhase   = phase
                failure       = FlatRenderer.line(for: event)
        }
    }

    func tick() {
        live  = ContinuousClock.now - began
        total = ContinuousClock.now - opened
    }

    /// Stops the clock on the build as a whole, so the card and the panel's
    /// last frame agree on how long it took.
    func finished(_ ok: Bool) {
        self.ok = ok
        total   = ContinuousClock.now - opened
        weighArtifacts()
    }

    /// The summary a finished phase wrote, which is what the card is made of.
    func summary(_ phase: Phase) -> String? {
        guard case .finished(let summary, _) = status[phase] else { return nil }
        return summary
    }

    func record() -> BuildRecord {
        BuildRecord(
            mode   : mode,
            kernel : kernelBytes ?? 0,
            initrd : initrdBytes ?? 0,
            elapsed: seconds(total),
            phases : Dictionary(uniqueKeysWithValues:
                elapsed.map { ($0.key.rawValue, seconds($0.value)) })
        )
    }

    /// The image phase already knows both sizes and says so in its summary, but
    /// a summary is prose. The bottom band subtracts, so it reads the bytes.
    private func weighArtifacts() {
        func bytes(_ name: String) -> Int? {
            let file = root.appending(path: ".reix/\(name)")
            return (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int
        }
        kernelBytes = bytes("kernel.bin")
        initrdBytes = bytes("initrd.tar")
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }
}
