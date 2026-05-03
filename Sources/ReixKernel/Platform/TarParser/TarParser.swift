//
//  TarParser.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

@_extern(c, "parse_tar")
public func parseTar(filename: UnsafePointer<CChar>, tarAddress: UInt64) -> UInt64
