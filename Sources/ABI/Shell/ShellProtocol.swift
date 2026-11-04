//
//  ShellProtocol.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public enum ShellProtocol {
    public static let version       : UInt16 = 1
    public static let headerBytes            = 16
    public static let recordBytes            = 8
    public static let maximumRecords: UInt16 = 32
    public static let maximumPayload         = 1024
}
