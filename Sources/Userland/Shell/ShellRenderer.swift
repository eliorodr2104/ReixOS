//
//  ShellRenderer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

enum ShellRenderer {
    @discardableResult
    static func present(_ records: ShellResult) -> Bool {
        for index in 0..<records.count {
            guard let record = records.record(at: index),
                  let presentation = ShellTextRenderer.render(record)
            else { ShellOutput.invalidate(); return false }
            for byte in 0..<presentation.count { putchar(ch: presentation.bytes[byte]) }
        }

        if records.truncated {
            guard let presentation = ShellTextRenderer.render(ShellResultRecord.truncated()) else { ShellOutput.invalidate(); return false }
            for byte in 0..<presentation.count { putchar(ch: presentation.bytes[byte]) }
        }
        return !ShellOutput.overflowed
    }

    @discardableResult
    static func present(_ frame: ShellFrame) -> Bool {
        let rendered = ShellTextRenderer.render(frame) { presentation in
            for index in 0..<presentation.count { putchar(ch: presentation.bytes[index]) }
            return !ShellOutput.overflowed
        }
        guard rendered else { ShellOutput.invalidate(); return false }
        return !ShellOutput.overflowed && !ShellOutput.failed
    }
}
