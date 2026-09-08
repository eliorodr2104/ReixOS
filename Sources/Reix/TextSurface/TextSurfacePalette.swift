//
//  TextSurfacePalette.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// How many colours the terminal on the other end is worth talking to in.
public enum ReixTerminalColorProfile: UInt8, Equatable {
    /// The eight colours and their bright halves, which every terminal has.
    case ansi16

    /// The 256-colour cube, which is what Gruvbox is written in.
    case indexed256
}

/// The one place a role becomes a colour.
///
/// Everything upstream of here speaks roles: the shell's analysis says
/// `command`, the editor says `selection`, and neither knows what either looks
/// like. This turns a role into SGR parameters and nothing else turns anything
/// into an escape.
///
/// The palette is Gruvbox, the machine's own theme. The sixteen-colour profile
/// is the same assignment coarsened, so a terminal that cannot do better still
/// tells a receiver from a verb.
public enum TextSurfacePalette {

    nonisolated(unsafe) public static var profile: ReixTerminalColorProfile = .indexed256

    /// The SGR parameters for a role, without the escape or the `m`.
    public static func parameters(for role: ReixTextSurfaceStyleRole) -> StaticString {
        switch profile {
            case .indexed256: return gruvbox(role)
            case .ansi16: return coarse(role)
        }
    }

    /// Gruvbox dark, by the palette's own names: aqua 108, green 142, yellow
    /// 214, orange 208, purple 175, blue 109, red 167, gray 245.
    private static func gruvbox(_ role: ReixTextSurfaceStyleRole) -> StaticString {
        switch role {
            case .plain, .input: return "0"
            case .prompt: return "1;38;5;108"
            case .selection: return "7"
            case .diagnostic: return "38;5;167"
            case .overlay: return "38;5;175"
            case .editorChrome: return "2;38;5;245"
            case .keyword: return "38;5;167"
            case .namespace: return "38;5;108"
            case .command: return "38;5;214"
            case .label: return "38;5;208"
            case .text: return "38;5;142"
            case .number: return "38;5;175"
            case .path: return "38;5;72"
            case .variable: return "38;5;109"
            case .member: return "38;5;66"
            case .closure: return "38;5;245"
            case .incomplete: return "38;5;245"
            case .error: return "4;38;5;167"
        }
    }

    private static func coarse(_ role: ReixTextSurfaceStyleRole) -> StaticString {
        switch role {
            case .plain, .input: return "0"
            case .prompt: return "1;36"
            case .selection: return "7"
            case .diagnostic: return "31"
            case .overlay: return "35"
            case .editorChrome: return "2"
            case .keyword: return "31"
            case .namespace: return "36"
            case .command: return "33"
            case .label: return "35"
            case .text: return "32"
            case .number: return "95"
            case .path: return "96"
            case .variable: return "34"
            case .member: return "94"
            case .closure: return "90"
            case .incomplete: return "90"
            case .error: return "4;31"
        }
    }
}
