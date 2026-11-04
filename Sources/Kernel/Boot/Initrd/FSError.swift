//
//  FSError.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//


public enum FSError: Error {
    case fileNotFound
    case permissionDenied
    case isDirectory
    case notADirectory
    case invalidArgument
    case readOnlyFileSystem
    case ioError
}
