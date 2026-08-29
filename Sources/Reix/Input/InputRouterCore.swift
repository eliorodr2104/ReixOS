//
//  InputRouterCore.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

import ReixABI

/// The capability-backed resources belonging to one router endpoint.
public struct InputBinding {
    public var identity: UInt32
    public var token: UInt32
    public var epoch: UInt64
    public var page: UnsafeMutablePointer<UInt8>?
    public var callback: UInt32
    public var ringGrant: UInt32

    public init(
        identity: UInt32 = 0,
        token: UInt32 = 0,
        epoch: UInt64 = 0,
        page: UnsafeMutablePointer<UInt8>? = nil,
        callback: UInt32 = 0,
        ringGrant: UInt32 = 0
    ) {
        self.identity = identity
        self.token = token
        self.epoch = epoch
        self.page = page
        self.callback = callback
        self.ringGrant = ringGrant
    }

    public var isEmpty: Bool { identity == 0 }
    public var hasRing: Bool { identity != 0 && token != 0 && epoch != 0 && page != nil }
    public var isSourceReady: Bool { hasRing && callback != 0 }
}

/// Per-session state held by the allocation-free router.
public struct InputSessionState {
    public var source = InputBinding()
    public var pendingSource = InputBinding()
    public var consumer = InputBinding()
    public var generation: UInt32 = 1
    public var sequence: UInt32 = 0
    public var pendingLost = false
    public var pendingGained = false
    public var pendingReset = false
}

public enum InputRouteKind {
    case data
    case focusLost
    case focusGained
    case stateReset
}

/// A single-use route reservation. Replacement invalidates its generation.
public struct InputRoutePlan {
    public let generation: UInt32
    public let session: Int
    public let callback: UInt32
    public let sequence: UInt32
    public let kind: InputRouteKind
}

public struct InputRouterMutation {
    public let status: ReixInputServerStatus
    public let first: InputBinding
    public let second: InputBinding
    public let third: InputBinding

    public init(
        status: ReixInputServerStatus,
        first: InputBinding = InputBinding(),
        second: InputBinding = InputBinding(),
        third: InputBinding = InputBinding()
    ) {
        self.status = status
        self.first = first
        self.second = second
        self.third = third
    }
}

public enum InputRouteStart {
    case plan(InputRoutePlan)
    case status(ReixInputServerStatus)
}

/// Pure InputServer router state. Syscalls and capability disposal stay outside.
public struct InputRouterCore {
    private static let maximumSessions = 4
    private var sessions = InlineArray<4, InputSessionState>(repeating: InputSessionState())
    private var focused: Int?
    private var pendingFocus: Int?

    public init() {}

    public mutating func stageSourceRing(_ session: Int, binding: InputBinding) -> InputRouterMutation {
        guard validSession(session), binding.hasRing, binding.callback == 0,
              validRing(binding)
        else {
            return InputRouterMutation(status: .malformed)
        }
        let old = sessions[session].pendingSource
        sessions[session].pendingSource = binding
        return InputRouterMutation(status: .ok, first: old)
    }

    public mutating func commitSourceCallback(
        _ session: Int,
        identity: UInt32,
        callback: UInt32
    ) -> InputRouterMutation {
        guard validSession(session), callback != 0,
              sessions[session].pendingSource.identity == identity,
              sessions[session].pendingSource.hasRing
        else {
            return InputRouterMutation(status: .stale)
        }
        sessions[session].pendingSource.callback = callback
        guard sessions[session].pendingSource.isSourceReady else {
            return InputRouterMutation(status: .stale)
        }
        let old = sessions[session].source
        sessions[session].source = sessions[session].pendingSource
        sessions[session].pendingSource = InputBinding()
        advanceGeneration(session)
        return InputRouterMutation(status: .ok, first: old)
    }

    public mutating func registerConsumer(_ session: Int, binding: InputBinding) -> InputRouterMutation {
        guard validSession(session), binding.hasRing, binding.callback == 0,
              validRing(binding)
        else {
            return InputRouterMutation(status: .malformed)
        }
        let old = sessions[session].consumer
        sessions[session].consumer = binding
        advanceGeneration(session)
        if focused == session {
            if old.isEmpty {
                sessions[session].pendingGained = true
            }
            sessions[session].pendingReset = true
        }
        return InputRouterMutation(status: .ok, first: old)
    }

    public mutating func focusTarget(_ target: Int) -> ReixInputServerStatus {
        guard validSession(target) else {
            return .refused
        }
        if let current = focused, let pending = pendingFocus {
            if target == pending {
                return .pending
            }
            if target == current {
                pendingFocus = nil
                sessions[current].pendingLost = false
                return .pending
            }
            pendingFocus = target
            return .pending
        }
        guard focused != target else {
            return .pending
        }
        if let current = focused, current != target, !sessions[current].consumer.isEmpty {
            sessions[current].pendingLost = true
            pendingFocus = target
            return .pending
        }
        activateFocus(target)
        return .pending
    }

    public mutating func sweepDeadIdentity(
        _ session: Int,
        sourceAlive: Bool,
        pendingSourceAlive: Bool,
        consumerAlive: Bool
    ) -> InputRouterMutation {
        guard validSession(session) else {
            return InputRouterMutation(status: .refused)
        }
        var first = InputBinding()
        var second = InputBinding()
        var third = InputBinding()
        var sourceChanged = false
        if !sourceAlive, !sessions[session].source.isEmpty {
            first = sessions[session].source
            sessions[session].source = InputBinding()
            sourceChanged = true
        }
        if !pendingSourceAlive, !sessions[session].pendingSource.isEmpty {
            let dead = sessions[session].pendingSource
            sessions[session].pendingSource = InputBinding()
            if first.isEmpty {
                first = dead
            } else {
                second = dead
            }
            sourceChanged = true
        }
        if sourceChanged {
            advanceGeneration(session)
        }
        if !consumerAlive, !sessions[session].consumer.isEmpty {
            let dead = sessions[session].consumer
            let wasFocused = focused == session
            let wasPendingTarget = pendingFocus == session
            sessions[session].consumer = InputBinding()
            sessions[session].pendingLost = false
            sessions[session].pendingGained = false
            sessions[session].pendingReset = false
            if wasFocused {
                focused = nil
            }
            if wasPendingTarget {
                pendingFocus = nil
                if let current = focused {
                    sessions[current].pendingLost = false
                }
            }
            if first.isEmpty {
                first = dead
            } else if second.isEmpty {
                second = dead
            } else {
                third = dead
            }
            if wasFocused, let target = pendingFocus {
                pendingFocus = nil
                activateFocus(target)
            }
            advanceGeneration(session)
        }
        return InputRouterMutation(status: .ok, first: first, second: second, third: third)
    }

    public mutating func beginRoute(_ session: Int) -> InputRouteStart {
        guard validSession(session), let consumer = ring(for: sessions[session].consumer) else {
            return .status(.stale)
        }
        let kind = pendingKind(session)
        guard !consumer.isFull else {
            return .status(.full)
        }
        if let kind {
            return .plan(plan(session, kind: kind, callback: 0))
        }
        guard focused == session, pendingFocus == nil,
              ring(for: sessions[session].source) != nil
        else {
            return .status(.stale)
        }
        guard sessions[session].source.callback != 0 else {
            return .status(.stale)
        }
        return .plan(plan(session, kind: .data, callback: sessions[session].source.callback))
    }

    public mutating func finishRoute(
        _ plan: InputRoutePlan,
        callbackSucceeded: Bool
    ) -> ReixInputServerStatus {
        guard validSession(plan.session), sessions[plan.session].generation == plan.generation,
              let consumer = ring(for: sessions[plan.session].consumer), !consumer.isFull
        else {
            return .stale
        }
        switch plan.kind {
            case .data:
                guard callbackSucceeded, let source = ring(for: sessions[plan.session].source) else {
                    return .stale
                }
                switch source.pop() {
                    case .status(let status):
                        return status
                    case .record(let record):
                        guard let event = resequence(record, sequence: plan.sequence) else {
                            return .malformed
                        }
                        let status = consumer.push(event)
                        guard status == .ok else {
                            return status
                        }
                        sessions[plan.session].sequence = plan.sequence
                        return .ok
                }
            case .focusLost, .focusGained, .stateReset:
                guard let event = ReixInputRecord(kind: controlKind(plan.kind), sequence: plan.sequence) else {
                    return .malformed
                }
                let status = consumer.push(event)
                guard status == .ok else {
                    return status
                }
                sessions[plan.session].sequence = plan.sequence
                completeControl(plan)
                return .ok
        }
    }

    public func sourceIdentity(_ session: Int) -> UInt32 {
        validSession(session) ? sessions[session].source.identity : 0
    }

    public func pendingSourceIdentity(_ session: Int) -> UInt32 {
        validSession(session) ? sessions[session].pendingSource.identity : 0
    }

    public func consumerIdentity(_ session: Int) -> UInt32 {
        validSession(session) ? sessions[session].consumer.identity : 0
    }

    mutating func setSequenceForTesting(_ value: UInt32, session: Int) {
        guard validSession(session) else {
            return
        }
        sessions[session].sequence = value
    }

    private func validSession(_ session: Int) -> Bool {
        session >= 0 && session < Self.maximumSessions
    }

    private func validRing(_ binding: InputBinding) -> Bool {
        ring(for: binding) != nil
    }

    private func ring(for binding: InputBinding) -> ReixInputRing? {
        guard let page = binding.page else {
            return nil
        }
        return ReixInputRing(page: page, token: binding.token, epoch: binding.epoch)
    }

    private mutating func advanceGeneration(_ session: Int) {
        sessions[session].generation = ReixInteractionSequence.nextCorrelated(
            after: sessions[session].generation
        )
    }

    private mutating func plan(_ session: Int, kind: InputRouteKind, callback: UInt32) -> InputRoutePlan {
        let sequence = ReixInteractionSequence.nextCorrelated(after: sessions[session].sequence)
        return InputRoutePlan(
            generation: sessions[session].generation,
            session: session,
            callback: callback,
            sequence: sequence,
            kind: kind
        )
    }

    private func pendingKind(_ session: Int) -> InputRouteKind? {
        if sessions[session].pendingLost {
            return .focusLost
        }
        if sessions[session].pendingGained {
            return .focusGained
        }
        if sessions[session].pendingReset {
            return .stateReset
        }
        return nil
    }

    private func controlKind(_ kind: InputRouteKind) -> ReixInputKind {
        switch kind {
            case .data:
                return .ignored
            case .focusLost:
                return .focusLost
            case .focusGained:
                return .focusGained
            case .stateReset:
                return .stateReset
        }
    }

    private mutating func completeControl(_ plan: InputRoutePlan) {
        switch plan.kind {
            case .focusLost:
                sessions[plan.session].pendingLost = false
                if let target = pendingFocus {
                    pendingFocus = nil
                    activateFocus(target)
                }
            case .focusGained:
                sessions[plan.session].pendingGained = false
            case .stateReset:
                sessions[plan.session].pendingReset = false
            case .data:
                break
        }
    }

    private mutating func activateFocus(_ target: Int) {
        focused = target
        guard !sessions[target].consumer.isEmpty else {
            return
        }
        sessions[target].pendingGained = true
        sessions[target].pendingReset = true
    }

    private func resequence(_ record: ReixInputRecord, sequence: UInt32) -> ReixInputRecord? {
        withUnsafeBytes(of: record.text) {
            let bytes = $0.bindMemory(to: UInt8.self)
            return ReixInputRecord(
                kind: record.kind,
                modifiers: record.modifiers,
                sequence: sequence,
                width: record.width,
                height: record.height,
                logicalKey: record.logicalKey,
                physicalKey: record.physicalKey,
                phase: record.phase,
                repeatCount: record.repeatCount,
                bytes: record.count == 0 ? nil : bytes.baseAddress,
                count: record.count
            )
        }
    }
}
