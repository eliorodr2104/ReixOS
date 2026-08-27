//
//  ShellCommandStatus.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

public enum ShellCommandStatus: UInt32 {
    case ok
    case refused
    case unavailable
    case failed
}
