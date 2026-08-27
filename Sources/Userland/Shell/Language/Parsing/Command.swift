//
//  Command.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// One parsed command: `receiver.verb(arguments)`.
public struct Command {
    public let receiver     : Span
    public let verb         : Span
    public var arguments    : InlineArray<4, Span> = InlineArray(repeating: Span(start: 0, count: 0))
    public var argumentCount: Int = 0

    public init(
          receiver: Span,
          verb    : Span
    ) {
        self.receiver = receiver
        self.verb = verb
    }
}
