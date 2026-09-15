//
//  BuildEvent.swift
//  ReixOS
//

import Foundation

/// The things a build does, in the order it does them. `programs` is the only
/// one a plain `reix build` skips: it provisions the disk and so belongs to a
/// boot, not to an image.
public enum Phase: String, CaseIterable, Sendable {
    case prune, compile, native, userland, image, disk, programs
}

/// Everything that crosses the line between doing the work and drawing it.
///
/// `why` carries what a phase is about to do and on what, stated before the
/// work rather than after it. It is the difference between a progress bar and
/// a report a reader can act on.
public enum BuildEvent: Sendable {
    case began   (Phase, why: String)
    case progress(Phase, done: Int, total: Int, now: String)
    case ended   (Phase, summary: String, elapsed: Duration)
    case skipped (Phase, because: String)
    case failed  (Phase, output: String)

    public var phase: Phase {
        switch self {
            case .began   (let p, _)      : return p
            case .progress(let p, _, _, _): return p
            case .ended   (let p, _, _)   : return p
            case .skipped (let p, _)      : return p
            case .failed  (let p, _)      : return p
        }
    }
}

/// Where events go. A closure and not a protocol: there is one implementation
/// per renderer and none of them needs to be subclassed.
public struct EventSink: Sendable {
    private let emit: @Sendable (BuildEvent) -> Void

    public init(_ emit: @escaping @Sendable (BuildEvent) -> Void) { self.emit = emit }

    public func callAsFunction(_ event: BuildEvent) { emit(event) }
}
