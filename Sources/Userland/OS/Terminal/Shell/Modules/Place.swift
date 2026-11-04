//
//  Place.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

/// Where a path points, once every name in it has been opened.
struct Place {
    var container: UInt32
    var folder   : UInt32
}
