//
//  ShellTextChunking.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

/// Sizes text records so their structural first/last decoration fits a single
/// terminal presentation frame. The values are payload bytes, not output bytes.
public enum ShellTextChunking {
    public static func amount(
          remaining: Int,
          first    : Bool
    ) -> Int {
        guard remaining > 0 else { return 0 }
        if first {
            // A one-record result needs its two-space prefix and trailing newline.
            if remaining <= 125 { return remaining }
            return remaining == 126 ? 125 : 126
        }
        // A final continuation needs one newline; only a non-final middle record
        // may carry the whole presentation payload.
        return min(remaining, remaining <= 128 ? 127 : 128)
    }
}
