//
//  Services.swift
//  ReixOS
//
//  Created by Eliomar on 02/08/2026.
//

/// TODO: - `processServer` is a name with nobody behind it. The server that
/// published it named its programs by an enum the build compiled in and went
/// with them; the case stays because it is what comes back, reading an image off
/// the volume instead.
public enum Services: UInt32 {
    case processServer = 0
    case fileSystem    = 1
    case terminal      = 2
}
