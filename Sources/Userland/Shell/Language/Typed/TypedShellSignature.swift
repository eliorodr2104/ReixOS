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

    /// One parameter, spelled where it is read. Modules declare signatures by
    /// hand, so the shape of a call should not cost them a table.
    public init(
        namespace        : StaticString,
        name             : StaticString,
        _ first          : TypedShellParameter,
        result           : ShellValueType = .void,
        effect           : ShellEffect = .service,
        namespaceRequired: Bool = false
    ) {
        var table = InlineArray<4, TypedShellParameter?>(repeating: nil)
        table[0] = first
        self.init(
            namespace        : namespace,
            name             : name,
            parameters       : table,
            parameterCount   : 1,
            result           : result,
            effect           : effect,
            namespaceRequired: namespaceRequired
        )
    }

    public init(
        namespace        : StaticString,
        name             : StaticString,
        _ first          : TypedShellParameter,
        _ second         : TypedShellParameter,
        result           : ShellValueType = .void,
        effect           : ShellEffect = .service,
        namespaceRequired: Bool = false
    ) {
        var table = InlineArray<4, TypedShellParameter?>(repeating: nil)
        table[0] = first
        table[1] = second
        self.init(
            namespace        : namespace,
            name             : name,
            parameters       : table,
            parameterCount   : 2,
            result           : result,
            effect           : effect,
            namespaceRequired: namespaceRequired
        )
    }
}
