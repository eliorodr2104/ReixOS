//
//  ShellEditorAllocationFault.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

/// The editor buffer an injected allocation failure applies to.
public enum ShellEditorAllocationSite: UInt8, Equatable {
    case storage     = 0
    case undo        = 1
    case history     = 2
    case pasteBackup = 3
}

/// Deterministic, per-editor allocation failure used by the host fault corpus.
/// It holds no global state, so the concurrent test runner cannot race it.
public struct ShellEditorAllocationFault: Equatable {
    public let site      : ShellEditorAllocationSite
    public let occurrence: Int

    public init(
        site      : ShellEditorAllocationSite,
        occurrence: Int = 1
    ) {
        self.site = site
        self.occurrence = max(1, occurrence)
    }
}
