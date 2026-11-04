//
//  Pipe.swift
//  ReixOS
//
//  Created by Eliomar on 24/08/2026.
//


public enum Pipe {
    public static let pages   : UInt64 = 1
    public static let pageSize: UInt64 = 4096
    public static var capacity: Int { Int(pages * pageSize) }
}
