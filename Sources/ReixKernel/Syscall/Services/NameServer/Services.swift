//
//  Services.swift
//  ReixOS
//
//  Well-known services the Name Server resolves. The rawValue doubles as the
//  index into the registry table.
//

public enum Services: UInt32 {
    case processServer = 0
    case fileSystem    = 1
    case terminal      = 2
}
