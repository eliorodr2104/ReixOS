//
//  InteractionSession.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

import Reix
import ReixABI

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

    public mutating func present(_ command: ReixTextSurfaceCommand) -> Bool {
        textSurface.present(command)
    }

    public mutating func resize(width: UInt16, height: UInt16, correlation: UInt32) -> Bool {
        textSurface.resize(width: width, height: height, correlation: correlation)
    }
}
