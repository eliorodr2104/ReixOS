//
//  ReixTextOutputKind.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

/// Why the record exists. The producer states the kind without knowing whether
/// the destination is a VT, a framebuffer or a log.
public enum ReixTextOutputKind: UInt8, Equatable {
    case application = 1
    case diagnostic  = 2
    case status      = 3
    case audit       = 4
}
