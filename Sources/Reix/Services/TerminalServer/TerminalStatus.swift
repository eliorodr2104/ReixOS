//
//  TerminalStatus.swift
//  ReixOS
//
//  Created by Eliomar on 25/08/2026.
//


/// What a terminal request answers.
public enum TerminalStatus: UInt32 {
    case ok           = 0
    case unregistered = 1
    case refused      = 2
    case malformed    = 3
}
