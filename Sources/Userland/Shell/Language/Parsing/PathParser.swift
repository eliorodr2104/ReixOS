//
//  PathParser.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

public enum PathParser {

    /// Takes `span` of `line` apart. Nothing is resolved and nothing is opened:
    /// this only says what was written.
    ///
    /// `count` is how long the line is, and it is not optional. A `Span` is two
    /// integers that do not carry the buffer they are about, so without the
    /// length this function had no way to tell a stretch of the line from a pair
    /// of numbers that pointed past the end of it - and it read where it was
    /// told either way. Every caller already had the length in hand; what it did
    /// not have was any obligation to pass it.
    ///
    /// The check is here rather than only at the shell's own door because the
    /// door is one caller among however many come later. A parser that refuses
    /// cannot be called unsafely by the next one.
    public static func parse(
        _ line: UnsafePointer<UInt8>,
          count : Int,
          span  : Span
    ) -> Result<PathParts, PathFailure> {

        guard span.isInside(count) else { return .failure(.notALine) }

        var parts  = PathParts()
        var cursor = span.start
        let end    = span.start + span.count

        guard span.count > 0 else { return .failure(.emptySegment) }

        // The container half: everything up to the last `::`, plus the first
        // name after it, which is a container too when there was one at all.
        var first = true

        while true {
            let start = cursor
            while cursor < end, line[cursor] != Self.colon, line[cursor] != Self.slash {
                cursor += 1
            }

            let segment = Span(start: start, count: cursor - start)
            guard segment.count > 0 else { return .failure(.emptySegment) }

            // A `::` after it means this segment was a container name, or the
            // root when it was the first thing on the line.
            let crossing = cursor + 1 < end
                && line[cursor] == Self.colon
                && line[cursor + 1] == Self.colon

            if cursor < end, line[cursor] == Self.colon, !crossing {
                return .failure(.loneColon)
            }

            guard crossing else {
                // No more crossings. This segment is a container when anything
                // has been crossed already, and a folder otherwise.
                if parts.isRooted {
                    guard parts.containerCount < parts.containers.count else {
                        return .failure(.tooDeep)
                    }
                    parts.containers[parts.containerCount] = segment
                    parts.containerCount += 1

                } else {
                    parts.folders[0]   = segment
                    parts.folderCount  = 1
                }
                break
            }

            if first {
                parts.root     = segment
                parts.isRooted = true

            } else {
                guard parts.containerCount < parts.containers.count else {
                    return .failure(.tooDeep)
                }
                parts.containers[parts.containerCount] = segment
                parts.containerCount += 1
            }

            first  = false
            cursor += 2

            // A crossing with nothing after it names the place just crossed
            // into. `reix::` is the machine, `reix::app::` is the container
            // called app, and neither needs a name for "here" invented for it.
            if cursor == end { return .success(parts) }
        }

        // The folder half: whatever `/` separates, after the last container.
        while cursor < end {
            guard line[cursor] == Self.slash else { return .failure(.loneColon) }
            cursor += 1

            let start = cursor
            while cursor < end, line[cursor] != Self.slash, line[cursor] != Self.colon {
                cursor += 1
            }

            let segment = Span(start: start, count: cursor - start)
            guard segment.count > 0 else { return .failure(.emptySegment) }

            guard parts.folderCount < parts.folders.count else { return .failure(.tooDeep) }

            parts.folders[parts.folderCount] = segment
            parts.folderCount += 1
        }

        return .success(parts)
    }


    private static let colon: UInt8 = 0x3A
    private static let slash: UInt8 = 0x2F
}
