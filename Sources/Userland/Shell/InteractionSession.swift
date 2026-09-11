//
//  InteractionSession.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

/// Keeps semantic input and text presentation together at the shell boundary.
public struct InteractionSession: ~Copyable {
    private var input      : InputSession
    private var textSurface: TextSurfaceSession

    public init?(
        input      : UInt32,
        textSurface: UInt32
    ) {

        guard let input = InputSession(endpoint: input) else { return nil }
        guard let textSurface = TextSurfaceSession(endpoint: textSurface) else {
            return nil
        }

        self.input       = input
        self.textSurface = textSurface
    }

    public mutating func nextInput() -> ReixInputRecord? {
        input.next()
    }

    public mutating func append(
        _ bytes     : UnsafePointer<UInt8>,
          count     : Int,
          sequence  : UInt32,
          styles    : UnsafePointer<ReixTextSurfaceStyleSpan>? = nil,
          styleCount: Int = 0
    ) -> Bool {
        textSurface.append(
            bytes,
            count: count,
            sequence: sequence,
            styles: styles,
            styleCount: styleCount
        )
    }

    public mutating func appendDiagnostic(
        _ bytes : UnsafePointer<UInt8>,
        count   : Int,
        sequence: UInt32
    ) -> Bool {
        textSurface.append(
            bytes,
            count: count,
            sequence: sequence,
            severity: .error,
            kind: .diagnostic
        )
    }

    /// False only when the region itself is gone. A refused frame is recoverable.
    public var isUsable: Bool { textSurface.isUsable }

    /// True when a refused frame left the surface expecting a whole line, not a patch.
    public var needsEditorSnapshot: Bool { textSurface.needsEditorSnapshot }

    public mutating func present(_ source: ShellEditorFrameSource) -> Bool {
        let frame = source.frame
        return textSurface.presentNative(
            kind: frame.kind,
            mode: frame.mode,
            correlation: frame.correlation,
            patchOffset: frame.patchOffset,
            replacedLength: frame.replacedLength,
            textLength: frame.textLength,
            text0: source.text0,
            text0Length: source.text0Length,
            text1: source.text1,
            text1Length: source.text1Length,
            text2: source.text2,
            text2Length: source.text2Length,
            styles: source.styles,
            styleCount: source.styleCount,
            columns: frame.columns,
            rows: frame.rows,
            cursorOffset: frame.cursorOffset,
            viewportRow: frame.viewportRow,
            viewportRows: frame.viewportRows,
            presentationRows: frame.presentationRows,
            overlay: source.overlay,
            overlayLength: source.overlayLength,
            overlayStyles: source.overlayStyles,
            overlayStyleCount: source.overlayStyleCount,
            overlayRow: frame.overlayRow,
            overlayColumn: frame.overlayColumn,
            overlayRows: frame.overlayRows,
            overlayColumns: frame.overlayColumns
        )
    }

    /// Starts the screen again, empty. What the shell asks for when a command
    /// said `clear`.
    @discardableResult
    public mutating func clear(sequence: UInt32) -> Bool {
        textSurface.clear(sequence: sequence)
    }

    @discardableResult
    public mutating func finishEditor(sequence: UInt32) -> Bool {
        textSurface.finishEditor(sequence: sequence)
    }

    public mutating func resize(width: UInt16, height: UInt16, correlation: UInt32) -> Bool {
        textSurface.resize(width: width, height: height, correlation: correlation)
    }
}
