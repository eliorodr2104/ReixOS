//
//  ContextSwitch-Bridge.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/04/2026.
//

@_silgen_name("jump_to_user_mode")
func jump_to_user_mode(
    trapFrame     : UnsafeMutablePointer<Arch.TrapFrame>,
    rootTable     : UInt64,
    kernelStackTop: UInt64
)
