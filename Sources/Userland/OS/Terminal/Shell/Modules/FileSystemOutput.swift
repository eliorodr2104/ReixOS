//
//  FileSystemOutput.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

enum FileSystemOutput {
    nonisolated(unsafe) static var records = ShellResult()
    nonisolated(unsafe) static var frame: ShellFrame? = nil

    static func begin() {
        records = ShellResult()
        frame = nil
    }

    static func take() -> ShellResult { records }
    static func takeFrame() -> ShellFrame? { frame }
    static func literal(_ text: StaticString) { _ = records.appendPresentation(text) }
    static func status(_ status: FSStatus) { _ = records.appendFileSystemStatus(status.rawValue) }
    static func room(_ state: (status: FSStatus, freeBlocks: UInt32, dirty: Bool, quarantined: Bool)) {
        if state.status == .ok {
            _ = records.appendFileSystemRoom(freeBlocks: state.freeBlocks, dirty: state.dirty, quarantined: state.quarantined)
        } else {
            status(state.status)
        }
    }
}
