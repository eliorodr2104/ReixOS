//
//  ShellEditorKeymap.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/08/2026.
//

import ReixABI

public enum ShellEditorIntent: Equatable {
    case moveLeft(Bool)
    case moveRight(Bool)
    case moveUp(Bool)
    case moveDown(Bool)
    case home(Bool)
    case end(Bool)
    case eraseBackward
    case eraseForward
    case submitOrNewline
    case newline
    case submit
    case historyPrevious
    case historyNext
    case pageUp
    case pageDown
    case undo
    case redo
    case complete
    case cancel
    case eof
}

/// One declarative mapping from semantic input to an editor intent.
public enum ShellEditorKeymap {
    public static func intent(
        key: ReixInputKey,
        modifiers: ReixInputModifiers
    ) -> ShellEditorIntent? {
        let selecting = modifiers.contains(.shift)
        switch key {
            case .left: return .moveLeft(selecting)
            case .right: return .moveRight(selecting)
            case .up: return .moveUp(selecting)
            case .down: return .moveDown(selecting)
            case .home: return .home(selecting)
            case .end: return .end(selecting)
            case .backspace: return .eraseBackward
            case .delete: return .eraseForward
            case .enter:
                if modifiers.contains(.control) { return .submit }
                if modifiers.contains(.shift) { return .newline }
                return .submitOrNewline
            case .historyPrevious: return .historyPrevious
            case .historyNext: return .historyNext
            case .pageUp: return .pageUp
            case .pageDown: return .pageDown
            case .undo: return .undo
            case .redo: return .redo
            case .tab: return .complete
            case .cancel: return .cancel
            case .eof: return .eof
            default: return nil
        }
    }
}
