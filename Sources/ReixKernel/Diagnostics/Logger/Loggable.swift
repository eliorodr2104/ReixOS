//
//  Loggable.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/08/2026.
//

/// Per-subsystem logging with a filter that costs nothing when it is shut.
///
/// A conforming type brings its own tag and its own threshold, which is
/// what retires the central `Subsystem` enum: the origin of a line is the
/// type that printed it, not an entry in a list somebody has to keep in
/// sync.
///
///     extension VirtualMemoryManager: Loggable {
///         static let nameLog : StaticString = "[VMM ]"
///         static let logLevel: LogLevel     = .info
///     }
///
///     Self.info("mapped \(pages) pages at 0x\(hex: virtual)")
///
/// Three properties this design depends on, in order of importance:
///
/// **It is static only.** Embedded Swift specializes `Self.info(...)` on
/// the concrete conforming type, and that specialization is what lets the
/// optimizer see `Self.logLevel` as a constant. An existential, `any
/// Loggable`, would erase the type, put the threshold behind a witness
/// table and destroy the whole point. Existentials are not supported here;
/// do not introduce one.
///
/// **The filter folds at compile time.** With `logLevel` declared as a
/// `static let` on the concrete type, `level >= Self.logLevel` reduces to a
/// constant and the guarded body is dropped. Because the message is an
/// `@autoclosure`, dropping the body also drops the interpolation that
/// would have built it: a `Self.debug(...)` in a `.warning` subsystem
/// leaves no instructions and no string bytes behind. Declare `logLevel`
/// as `static let`, never as a computed property reading a global, or the
/// fold does not happen.
///
/// **The message is never a `String`.** `LogMessage` reads like a string
/// at the call site but every segment streams straight to `LogSink` as it
/// is appended. A `String` parameter would put the line on the heap, which
/// the early-boot and panic paths do not have.
public protocol Loggable {

    /// Fixed-width origin tag, brackets included: `"[VMM ]"`. Six
    /// characters, like every other tag in the log, so columns stay aligned
    /// across the whole boot log and runtime traces.
    static var nameLog : StaticString { get }

    /// Lowest level this subsystem emits. Anything below it is compiled
    /// out entirely.
    static var logLevel: LogLevel { get }
}


public extension Loggable {

    /// Subsystems that do not say otherwise emit everything except debug.
    static var logLevel: LogLevel { .info }


    @inline(__always)
    static func debug  (_ message: @autoclosure () -> LogMessage) { log(.debug,   message()) }

    @inline(__always)
    static func info   (_ message: @autoclosure () -> LogMessage) { log(.info,    message()) }

    @inline(__always)
    static func message(_ message: @autoclosure () -> LogMessage) { log(.message, message()) }

    @inline(__always)
    static func warning(_ message: @autoclosure () -> LogMessage) { log(.warning, message()) }

    @inline(__always)
    static func error  (_ message: @autoclosure () -> LogMessage) { log(.error,   message()) }

    @inline(__always)
    static func boot   (_ message: @autoclosure () -> LogMessage) { log(.boot,    message()) }

    /// Prints at panic severity. It does **not** halt, `Arch.CPU.panic`
    /// does that. Never buffered, whatever the sink mode is.
    @inline(__always)
    static func panic  (_ message: @autoclosure () -> LogMessage) { log(.panic,   message()) }


    /// The one place the three steps live.
    ///
    /// `message()` reaches this call still wrapped: passing the result of
    /// an `@autoclosure` into another `@autoclosure` parameter re-wraps it
    /// rather than evaluating it, so the interpolation still runs *after*
    /// the record has been opened, and not at all when the guard rejects.
    @inline(__always)
    static func log(
        _ level  : LogLevel,
        _ message: @autoclosure () -> LogMessage
    ) {
        guard level >= Self.logLevel else { return }

        LogSink.beginRecord(level: level, tag: Self.nameLog)
        _ = message()
        LogSink.endRecord()
    }
}
