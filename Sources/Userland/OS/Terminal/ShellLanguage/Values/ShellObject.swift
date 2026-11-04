//
//  ShellObject.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public struct ShellObject: Equatable {
    public let kind   : UInt16
    public let name   : ShellText
    public let number0: UInt64
    public let number1: UInt64
    public let flags  : UInt32

    public init(
          kind   : UInt16,
          name   : ShellText = ShellText(),
          number0: UInt64 = 0,
          number1: UInt64 = 0,
          flags  : UInt32 = 0
    ) {
        self.kind = kind
        self.name = name
        self.number0 = number0
        self.number1 = number1
        self.flags = flags
    }
}
