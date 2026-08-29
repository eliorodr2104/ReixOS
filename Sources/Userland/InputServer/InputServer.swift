//
//  InputServer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

import Reix
import ReixABI

/// Maps IPC-owned capabilities onto the syscall-free input router.
public struct InputServer: Service {
    public static let manifest = ServiceManifest(provides: .parent)

    private let endpoint: UInt32
    private var router = InputRouterCore()

    public var serviceEndpoint: UInt32 { endpoint }

    public init(environment: Environment, endpoint: UInt32) {
        self.endpoint = endpoint
        print("[ SERVE ] Input Server running")
    }

    public mutating func handle(_ operation: ReixInputServerOperation, request: inout ReceivedMessage) {
        guard let access = ReixInputAccess(rawValue: request.session),
              let session = sessionIndex(access.session)
        else {
            return
        }
        sweep(session)
        switch operation {
            case .registerSourceRing:
                registerSourceRing(session, access, &request)
            case .registerSourceCallback:
                registerSourceCallback(session, access, &request)
            case .registerConsumer:
                registerConsumer(session, access, &request)
            case .pull:
                pull(session, access, &request)
            case .focus:
                focus(session, access)
            case .status:
                status(session, access, request)
        }
    }

    private func sessionIndex(_ session: UInt32) -> Int? {
        guard session > 0, session <= 4 else {
            return nil
        }
        return Int(session - 1)
    }

    private mutating func sweep(_ session: Int) {
        let source = router.sourceIdentity(session)
        let pendingSource = router.pendingSourceIdentity(session)
        let consumer = router.consumerIdentity(session)
        let mutation = router.sweepDeadIdentity(
            session,
            sourceAlive: source == 0 || identityAlive(source),
            pendingSourceAlive: pendingSource == 0 || identityAlive(pendingSource),
            consumerAlive: consumer == 0 || identityAlive(consumer)
        )
        discard(mutation.first)
        discard(mutation.second)
        discard(mutation.third)
    }

    private mutating func registerSourceRing(
        _ session: Int,
        _ access: ReixInputAccess,
        _ request: inout ReceivedMessage
    ) {
        guard access.role == .source,
              request.message.tag.length == 2,
              let offered = request.grantedCap,
              request.message.words[0] != 0,
              request.message.words[1] != 0,
              shmPages(handle: offered) == 1,
              let page = UnsafeMutableRawPointer(bitPattern: UInt(shmMap(handle: offered)))?
                .assumingMemoryBound(to: UInt8.self)
        else {
            return
        }
        guard let grant = request.takeGrant() else {
            _ = munmap(addr: UInt64(UInt(bitPattern: page)), size: UInt64(ReixInputRing.pageBytes))
            return
        }
        let binding = InputBinding(
            identity: request.identity,
            token: request.message.words[0],
            epoch: UInt64(request.message.words[1]),
            page: page,
            ringGrant: grant
        )
        let mutation = router.stageSourceRing(session, binding: binding)
        guard mutation.status == .ok else {
            discard(binding)
            return
        }
        discard(mutation.first)
    }

    private mutating func registerSourceCallback(
        _ session: Int,
        _ access: ReixInputAccess,
        _ request: inout ReceivedMessage
    ) {
        guard access.role == .source,
              request.message.tag.length == 0,
              let callback = request.takeGrant()
        else {
            return
        }
        let mutation = router.commitSourceCallback(session, identity: request.identity, callback: callback)
        guard mutation.status == .ok else {
            _ = capDrop(callback)
            return
        }
        discard(mutation.first)
    }

    private mutating func registerConsumer(
        _ session: Int,
        _ access: ReixInputAccess,
        _ request: inout ReceivedMessage
    ) {
        guard access.role == .consumer,
              request.message.tag.length == 2,
              let offered = request.grantedCap,
              request.message.words[0] != 0,
              request.message.words[1] != 0,
              shmPages(handle: offered) == 1,
              let page = UnsafeMutableRawPointer(bitPattern: UInt(shmMap(handle: offered)))?
                .assumingMemoryBound(to: UInt8.self)
        else {
            return
        }
        guard let grant = request.takeGrant() else {
            _ = munmap(addr: UInt64(UInt(bitPattern: page)), size: UInt64(ReixInputRing.pageBytes))
            return
        }
        let binding = InputBinding(
            identity: request.identity,
            token: request.message.words[0],
            epoch: UInt64(request.message.words[1]),
            page: page,
            ringGrant: grant
        )
        let mutation = router.registerConsumer(session, binding: binding)
        guard mutation.status == .ok else {
            discard(binding)
            return
        }
        discard(mutation.first)
    }

    private mutating func pull(_ session: Int, _ access: ReixInputAccess, _ request: inout ReceivedMessage) {
        guard access.role == .consumer,
              router.consumerIdentity(session) == request.identity
        else {
            replyStatus(.pull, .stale)
            return
        }
        switch router.beginRoute(session) {
            case .status(let status):
                replyStatus(.pull, status)
            case .plan(let plan):
                if plan.callback == 0 {
                    replyStatus(.pull, router.finishRoute(plan, callbackSucceeded: true))
                    return
                }
                let callback = invokeSource(plan.callback, sequence: plan.sequence)
                guard callback == .ok else {
                    replyStatus(.pull, callback)
                    return
                }
                replyStatus(.pull, router.finishRoute(plan, callbackSucceeded: true))
        }
    }

    private mutating func focus(_ session: Int, _ access: ReixInputAccess) {
        guard access.role == .focusController else {
            return
        }
        replyStatus(.focus, router.focusTarget(session))
    }

    private func status(_ session: Int, _ access: ReixInputAccess, _ request: ReceivedMessage) {
        let result: ReixInputServerStatus
        switch access.role {
            case .source:
                result = router.sourceIdentity(session) == request.identity ? .ok : .stale
            case .consumer:
                result = router.consumerIdentity(session) == request.identity ? .ok : .stale
            case .focusController:
                result = .refused
        }
        replyStatus(.status, result)
    }

    private func invokeSource(_ callback: UInt32, sequence: UInt32) -> ReixInputServerStatus {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = sequence
        guard case .success(let reply) = call(
            handle: callback,
            message: Message(tag: MessageTag(ReixInputSourceOperation.produce, length: 1), words: words)
        ) else {
            return .stale
        }
        guard let status = ReixInputSourceStatus(rawValue: reply.message.words[0]) else {
            return .malformed
        }
        switch status {
            case .ok:
                return .ok
            case .empty:
                return .empty
            case .timedOut:
                return .timedOut
            case .stale:
                return .stale
            case .refused:
                return .refused
        }
    }

    private func discard(_ binding: InputBinding) {
        if let page = binding.page {
            _ = munmap(addr: UInt64(UInt(bitPattern: page)), size: UInt64(ReixInputRing.pageBytes))
        }
        if binding.ringGrant != 0 {
            _ = capDrop(binding.ringGrant)
        }
        if binding.callback != 0 {
            _ = capDrop(binding.callback)
        }
    }

    private func replyStatus(_ operation: ReixInputServerOperation, _ status: ReixInputServerStatus) {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = status.rawValue
        _ = reply(message: Message(tag: MessageTag(operation, length: 1), words: words))
    }
}
