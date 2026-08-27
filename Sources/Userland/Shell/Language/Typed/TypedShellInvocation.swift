//
//  TypedShellInvocation.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public struct TypedShellInvocation {
    public let signatureIndex: Int
    public let arguments     : InlineArray<4, TypedShellArgument?>
    public let argumentCount : Int
}
