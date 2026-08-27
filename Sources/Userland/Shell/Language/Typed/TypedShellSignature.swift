//
//  TypedShellSignature.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public struct TypedShellSignature {
    public let namespace        : StaticString
    public let name             : StaticString
    public let parameters       : InlineArray<4, TypedShellParameter?>
    public let parameterCount   : Int
    public let result           : ShellValueType
    public let effect           : ShellEffect
    public let namespaceRequired: Bool

    public init(
        namespace        : StaticString,
        name             : StaticString,
        parameters       : InlineArray<4, TypedShellParameter?> = InlineArray(repeating: nil),
        parameterCount   : Int = 0,
        result           : ShellValueType = .void,
        effect           : ShellEffect = .service,
        namespaceRequired: Bool = false
    ) {
        self.namespace = namespace
        self.name = name
        self.parameters = parameters
        self.parameterCount = parameterCount
        self.result = result
        self.effect = effect
        self.namespaceRequired = namespaceRequired
    }
}
