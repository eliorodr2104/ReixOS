//
//  FlatRenderer.swift
//  ReixOS
//

import Foundation

/// One line per event, for everything that is not a terminal: CI, a pipe, the
/// Xcode build log, the shell scripts.
///
/// Two columns, the same two the plugin's report used. A reader scanning for
/// the thing that changed finds it in the same column every time.
public enum FlatRenderer {

    /// The line this event deserves, or nothing when it deserves none.
    public static func line(for event: BuildEvent) -> String? {
        switch event {
            case .began(let phase, let why):
                return column(phase) + why + " ..."

            case .ended(let phase, let summary, _):
                return column(phase) + summary

            case .skipped(let phase, let because):
                return column(phase) + "skipped, " + because

            case .failed(let phase, let output):
                // Never reflowed and never truncated: it is the thing being read.
                return column(phase) + "FAILED\n" + output

            case .progress, .output:
                // Nothing here can redraw a line, so a count would just be noise,
                // and the tool's own lines are what `--verbose` and the log carry.
                return nil
        }
    }

    private static func column(_ phase: Phase) -> String {
        "  " + phase.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
    }
}
