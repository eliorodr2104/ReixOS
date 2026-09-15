//
//  PhaseRunner.swift
//  ReixOS
//

import Foundation

/// Runs the phases in order, brackets each one, and stops at the first failure.
///
/// It knows nothing about what a phase does. That is the point: the same engine
/// runs the real build, and runs four closures in a test with no terminal, no
/// compiler and no disk.
public struct PhaseRunner {

    public enum Outcome: Sendable {
        case done   (String)
        case skipped(String)
    }

    public struct Step: Sendable {
        public let phase: Phase
        public let why  : String
        public let body : @Sendable (EventSink) async throws -> Outcome

        public init(
            phase: Phase,
            why  : String,
            body : @escaping @Sendable (EventSink) async throws -> Outcome
        ) {
            self.phase = phase
            self.why   = why
            self.body  = body
        }
    }

    /// True when every step ran without throwing.
    @discardableResult
    public static func run(_ steps: [Step], into sink: EventSink) async -> Bool {
        let clock = ContinuousClock()

        for step in steps {
            sink(.began(step.phase, why: step.why))
            let start = clock.now

            do {
                switch try await step.body(sink) {
                    case .done(let summary):
                        sink(.ended(step.phase, summary: summary, elapsed: clock.now - start))
                    case .skipped(let because):
                        sink(.skipped(step.phase, because: because))
                }
            } catch {
                // The tool's own words, not ours. A reader has to read them.
                sink(.failed(step.phase, output: "\(error)"))
                return false
            }
        }
        return true
    }
}
