//
//  ShellEditorFrame.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/08/2026.
//

import ReixABI

/// Metadata for one native TextSurface frame built from editor-owned storage.
public struct ShellEditorFrame {
    public let kind: ReixTextSurfaceFrameKind
    public let correlation: UInt32
    public let patchOffset: UInt32
    public let replacedLength: UInt32
    public let textLength: UInt32
    public let columns: UInt16
    public let rows: UInt16
    public let cursorOffset: UInt32
    public let cursorRow: UInt16
    public let cursorColumn: UInt16
    public let viewportRow: UInt16
    public let viewportRows: UInt16
}

/// A scoped view. Its pointers are valid only while the producer closure runs.
public struct ShellEditorFrameSource {
    public let frame: ShellEditorFrame
    public let text0: UnsafePointer<UInt8>?
    public let text0Length: Int
    public let text1: UnsafePointer<UInt8>?
    public let text1Length: Int
    public let text2: UnsafePointer<UInt8>?
    public let text2Length: Int
    public let styles: UnsafePointer<ReixTextSurfaceStyleSpan>
    public let styleCount: Int
}
