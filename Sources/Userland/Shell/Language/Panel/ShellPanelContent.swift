//
//  ShellPanelContent.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// What a panel can be filled with.
///
/// The box is one component; these are the things worth putting in it. Adding
/// another is adding a function here, not another box.
public extension ShellPanel {

    /// The candidates that fit where the cursor is.
    static func candidates(
        _ set  : ShellCompletionSet,
          title: StaticString
    ) -> ShellPanel {
        var panel = ShellPanel(title: title)
        for index in 0..<set.count {
            guard let candidate = set.candidate(at: index) else { continue }
            panel.append(candidate.withName { bytes, count in
                ShellPanelRow(
                    bytes    : bytes,
                    count    : count,
                    detail   : candidate.detail,
                    summary  : candidate.summary,
                    suffix   : candidate.suffix,
                    caret    : candidate.caret,
                    sensitive: candidate.sensitive,
                    role     : role(of: candidate.kind)
                )
            })
        }
        panel.note(missing: set.matched - set.count)
        return panel
    }

    /// What one command is: what it answers with, what it changes, and the
    /// authority it acts through.
    static func documentation(_ descriptor: ShellCommandDescriptor) -> ShellPanel {
        var panel = ShellPanel(title: descriptor.signature.name)
        for position in 0..<descriptor.signature.parameterCount {
            guard let parameter = descriptor.signature.parameters[position] else { continue }
            panel.append(ShellPanelRow(
                name   : parameter.label,
                detail : ShellCompletionEngine.typeName(parameter.type),
                summary: descriptor.summary,
                role   : .label
            ))
        }
        panel.append(ShellPanelRow(
            name   : "answers",
            detail : descriptor.schema.isEmptyType
                ? ShellCompletionEngine.typeName(descriptor.signature.result)
                : descriptor.schema.name,
            summary: descriptor.summary,
            role   : .member
        ))
        panel.append(ShellPanelRow(
            name     : "changes",
            detail   : effectName(descriptor.signature.effect),
            summary  : descriptor.summary,
            sensitive: descriptor.sensitive,
            role     : .member
        ))
        panel.append(ShellPanelRow(
            name   : "through",
            detail : capabilityName(descriptor.capability),
            summary: descriptor.summary,
            role   : .member
        ))
        return panel
    }

    /// What a value of this shape is made of.
    static func members(
        of schema: ShellTypeSchema,
        title    : StaticString
    ) -> ShellPanel {
        var panel = ShellPanel(title: title)
        for index in 0..<ShellCatalog.memberCount(of: schema) {
            guard let member = ShellCatalog.member(of: schema, at: index) else { continue }
            panel.append(ShellPanelRow(
                name   : member.name,
                detail : member.type.name,
                summary: member.summary,
                role   : .member
            ))
        }
        for index in 0..<ShellCatalog.methodCount(of: schema) {
            guard let method = ShellCatalog.method(of: schema, at: index) else { continue }
            panel.append(ShellPanelRow(
                name   : method.name,
                detail : method.result.name,
                summary: method.summary,
                role   : .member
            ))
        }
        return panel
    }

    private static func role(of kind: ShellCompletionKind) -> ReixTextSurfaceStyleRole {
        switch kind {
            case .namespace: return .namespace
            case .command: return .command
            case .label: return .label
            case .member, .method: return .member
            case .variable: return .variable
            case .keyword: return .keyword
            case .path: return .path
        }
    }

    private static func effectName(_ effect: ShellEffect) -> StaticString {
        switch effect {
            case .pure: return "nothing"
            case .service: return "the disk"
            case .session: return "this shell"
            case .machine: return "the machine"
        }
    }

    private static func capabilityName(_ capability: BootCap?) -> StaticString {
        guard let capability else { return "no authority" }
        switch capability {
            case .console: return "console"
            case .nameServer: return "name server"
            case .spawn: return "spawn"
            case .device: return "device"
            case .profiler: return "profiler"
            case .terminal: return "terminal"
            case .container: return "container"
            case .shared: return "shared"
            case .block: return "block"
            case .processServer: return "process server"
            case .sessionControl: return "session control"
            case .programs: return "programs"
            default: return "a capability"
        }
    }
}
