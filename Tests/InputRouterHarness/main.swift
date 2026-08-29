//
//  main.swift
//  ReixOS
//
//  Input router host regression harness.
//

import KernelHostShims
@testable import Reix
import ReixABI

private var checks = 0
private var failures = 0
private var scenario = "startup"

private enum HarnessError: Error {
    case requiredValue
}

private func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
    failures += 1
    print("InputRouterHarness failure [\(scenario)] \(file):\(line): \(message)")
}

private func XCTAssertTrue(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "expected true",
    file: StaticString = #fileID,
    line: UInt = #line
) {
    checks += 1
    if !condition() {
        fail(message, file: file, line: line)
    }
}

private func XCTAssertNil<T>(
    _ value: @autoclosure () -> T?,
    _ message: String = "expected nil",
    file: StaticString = #fileID,
    line: UInt = #line
) {
    checks += 1
    if value() != nil {
        fail(message, file: file, line: line)
    }
}

private func XCTAssertEqual<T: Equatable>(
    _ actual: @autoclosure () -> T,
    _ expected: @autoclosure () -> T,
    _ message: String = "values differ",
    file: StaticString = #fileID,
    line: UInt = #line
) {
    checks += 1
    if actual() != expected() {
        fail(message, file: file, line: line)
    }
}

private func XCTAssertNotEqual<T: Equatable>(
    _ actual: @autoclosure () -> T,
    _ expected: @autoclosure () -> T,
    _ message: String = "values unexpectedly match",
    file: StaticString = #fileID,
    line: UInt = #line
) {
    checks += 1
    if actual() == expected() {
        fail(message, file: file, line: line)
    }
}

private func XCTAssertLessThanOrEqual<T: Comparable>(
    _ actual: @autoclosure () -> T,
    _ expected: @autoclosure () -> T,
    _ message: String = "value exceeds bound",
    file: StaticString = #fileID,
    line: UInt = #line
) {
    checks += 1
    if actual() > expected() {
        fail(message, file: file, line: line)
    }
}

private func XCTFail(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
    checks += 1
    fail(message, file: file, line: line)
}

private func XCTUnwrap<T>(
    _ value: @autoclosure () -> T?,
    _ message: String = "required value is nil",
    file: StaticString = #fileID,
    line: UInt = #line
) throws -> T {
    checks += 1
    guard let unwrapped = value() else {
        fail(message, file: file, line: line)
        throw HarnessError.requiredValue
    }
    return unwrapped
}

private final class InputRouterHarness {
    func testInputAccessRoundTripAndRejectsInvalidWords() throws {
        for role in [ReixInputAccess.Role.source, .consumer, .focusController] {
            let access = try XCTUnwrap(ReixInputAccess(role: role, session: 4))
            XCTAssertEqual(ReixInputAccess(rawValue: access.rawValue), access)
        }

        XCTAssertNil(ReixInputAccess(rawValue: 0))
        XCTAssertNil(ReixInputAccess(rawValue: UInt64(4) << 56 | 1))
        XCTAssertNil(ReixInputAccess(rawValue: UInt64(1) << 56))
        XCTAssertNil(ReixInputAccess(rawValue: UInt64(1) << 56 | 0x01_00_00_00))
        XCTAssertNil(ReixInputAccess(role: .source, session: 0))
        XCTAssertNil(ReixInputAccess(role: .source, session: 0x01_00_00_00))
        XCTAssertNotEqual(
            ReixInputAccess(role: .source, session: 1),
            ReixInputAccess(role: .source, session: 2)
        )
    }

    func testRoutesSourceRecordToConsumerWithExactFields() throws {
        let source = page(token: 11, epoch: 1)
        let consumer = page(token: 12, epoch: 1)
        defer {
            source.deallocate()
            consumer.deallocate()
        }
        var core = configured(source: source, consumer: consumer, sourceToken: 11, consumerToken: 12)
        drainControls(&core, session: 0)
        let sourceRing = try XCTUnwrap(ReixInputRing(page: source, token: 11, epoch: 1))
        let consumerRing = try XCTUnwrap(ReixInputRing(page: consumer, token: 12, epoch: 1))
        let bytes: [UInt8] = [65]
        let input = try XCTUnwrap(
            bytes.withUnsafeBufferPointer {
                ReixInputRecord(
                    kind: .insert,
                    modifiers: [.shift, .alt],
                    sequence: 91,
                    bytes: $0.baseAddress,
                    count: $0.count
                )
            }
        )
        XCTAssertEqual(sourceRing.push(input), .ok)

        let plan = try dataPlan(&core, session: 0)
        XCTAssertEqual(plan.callback, 77)
        XCTAssertEqual(core.finishRoute(plan, callbackSucceeded: true), .ok)

        let delivered = try record(from: consumerRing)
        XCTAssertEqual(delivered.kind, .insert)
        XCTAssertEqual(delivered.modifiers, [.shift, .alt])
        XCTAssertEqual(delivered.sequence, plan.sequence)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.text[0], 65)
    }

    func testFullConsumerDoesNotConsumeSource() throws {
        let source = page(token: 21, epoch: 1)
        let consumer = page(token: 22, epoch: 1)
        defer {
            source.deallocate()
            consumer.deallocate()
        }
        var core = configured(source: source, consumer: consumer, sourceToken: 21, consumerToken: 22)
        drainControls(&core, session: 0)
        let sourceRing = try XCTUnwrap(ReixInputRing(page: source, token: 21, epoch: 1))
        let consumerRing = try XCTUnwrap(ReixInputRing(page: consumer, token: 22, epoch: 1))
        let input = try XCTUnwrap(ReixInputRecord(kind: .enter, sequence: 1))
        XCTAssertEqual(sourceRing.push(input), .ok)
        fill(consumerRing)
        let sourceConsumer = consumerCursor(source)

        XCTAssertEqual(routeStatus(core.beginRoute(0)), .full)
        XCTAssertEqual(consumerCursor(source), sourceConsumer)
        XCTAssertEqual(sourceRing.pop().recordOrStatus, .ok)
    }

    func testMalformedSourceDoesNotAdvanceCursorAcrossRetries() throws {
        let source = page(token: 31, epoch: 1)
        let consumer = page(token: 32, epoch: 1)
        defer {
            source.deallocate()
            consumer.deallocate()
        }
        var core = configured(source: source, consumer: consumer, sourceToken: 31, consumerToken: 32)
        drainControls(&core, session: 0)
        let sourceRing = try XCTUnwrap(ReixInputRing(page: source, token: 31, epoch: 1))
        let input = try XCTUnwrap(ReixInputRecord(kind: .enter, sequence: 1))
        XCTAssertEqual(sourceRing.push(input), .ok)
        source[ReixInputRing.headerBytes] = 0
        let before = consumerCursor(source)

        let first = try dataPlan(&core, session: 0)
        XCTAssertEqual(core.finishRoute(first, callbackSucceeded: true), .malformed)
        XCTAssertEqual(consumerCursor(source), before)

        let second = try dataPlan(&core, session: 0)
        XCTAssertEqual(core.finishRoute(second, callbackSucceeded: true), .malformed)
        XCTAssertEqual(consumerCursor(source), before)
    }

    func testCallbackFailureDoesNotConsumeSource() throws {
        let source = page(token: 41, epoch: 1)
        let consumer = page(token: 42, epoch: 1)
        defer {
            source.deallocate()
            consumer.deallocate()
        }
        var core = configured(source: source, consumer: consumer, sourceToken: 41, consumerToken: 42)
        drainControls(&core, session: 0)
        let sourceRing = try XCTUnwrap(ReixInputRing(page: source, token: 41, epoch: 1))
        let input = try XCTUnwrap(ReixInputRecord(kind: .enter, sequence: 1))
        XCTAssertEqual(sourceRing.push(input), .ok)
        let before = consumerCursor(source)

        let plan = try dataPlan(&core, session: 0)
        XCTAssertEqual(core.finishRoute(plan, callbackSucceeded: false), .stale)
        XCTAssertEqual(consumerCursor(source), before)
        XCTAssertEqual(sourceRing.pop().recordOrStatus, .ok)
    }

    func testTokenAndEpochCorruptionReturnStaleWithoutCursorMovement() throws {
        let source = page(token: 51, epoch: 1)
        let consumer = page(token: 52, epoch: 1)
        defer {
            source.deallocate()
            consumer.deallocate()
        }
        var core = configured(source: source, consumer: consumer, sourceToken: 51, consumerToken: 52)
        drainControls(&core, session: 0)
        let sourceRing = try XCTUnwrap(ReixInputRing(page: source, token: 51, epoch: 1))
        let input = try XCTUnwrap(ReixInputRecord(kind: .enter, sequence: 1))
        XCTAssertEqual(sourceRing.push(input), .ok)
        let sourceBefore = CursorPair(page: source)
        source[24] ^= 1
        XCTAssertEqual(routeStatus(core.beginRoute(0)), .stale)
        XCTAssertEqual(CursorPair(page: source), sourceBefore)
        source[24] ^= 1

        let consumerBefore = CursorPair(page: consumer)
        consumer[16] ^= 1
        XCTAssertEqual(routeStatus(core.beginRoute(0)), .stale)
        XCTAssertEqual(CursorPair(page: consumer), consumerBefore)
    }

    func testSourceStagePreservesActiveAndCommitReturnsOldBinding() throws {
        let active = page(token: 61, epoch: 1)
        let pending = page(token: 62, epoch: 1)
        let consumer = page(token: 63, epoch: 1)
        defer {
            active.deallocate()
            pending.deallocate()
            consumer.deallocate()
        }
        var core = configured(source: active, consumer: consumer, sourceToken: 61, consumerToken: 63)
        drainControls(&core, session: 0)
        XCTAssertEqual(core.stageSourceRing(0, binding: binding(3, 62, pending)).status, .ok)
        XCTAssertEqual(core.sourceIdentity(0), 1)
        XCTAssertEqual(core.pendingSourceIdentity(0), 3)
        let stalePlan = try dataPlan(&core, session: 0)

        let mutation = core.commitSourceCallback(0, identity: 3, callback: 88)
        XCTAssertEqual(mutation.status, .ok)
        XCTAssertEqual(mutation.first.identity, 1)
        XCTAssertEqual(core.sourceIdentity(0), 3)
        XCTAssertEqual(core.pendingSourceIdentity(0), 0)
        XCTAssertEqual(core.finishRoute(stalePlan, callbackSucceeded: true), .stale)
    }

    func testFocusBeforeConsumerDeliversGainedThenReset() throws {
        let consumer = page(token: 71, epoch: 1)
        defer {
            consumer.deallocate()
        }
        var core = InputRouterCore()
        XCTAssertEqual(core.focusTarget(0), .pending)
        XCTAssertEqual(core.registerConsumer(0, binding: binding(1, 71, consumer)).status, .ok)

        XCTAssertEqual(controlKinds(&core, session: 0), [.focusGained, .stateReset])
    }

    func testFocusTransferOrdersControlsAndBlocksDataDuringTransition() throws {
        let source = page(token: 81, epoch: 1)
        let first = page(token: 82, epoch: 1)
        let second = page(token: 83, epoch: 1)
        defer {
            source.deallocate()
            first.deallocate()
            second.deallocate()
        }
        var core = configured(source: source, consumer: first, sourceToken: 81, consumerToken: 82)
        XCTAssertEqual(core.registerConsumer(1, binding: binding(3, 83, second)).status, .ok)
        drainControls(&core, session: 0)
        let sourceRing = try XCTUnwrap(ReixInputRing(page: source, token: 81, epoch: 1))
        let input = try XCTUnwrap(ReixInputRecord(kind: .enter, sequence: 1))
        XCTAssertEqual(sourceRing.push(input), .ok)
        XCTAssertEqual(core.focusTarget(1), .pending)

        XCTAssertEqual(controlKinds(&core, session: 0), [.focusLost])
        XCTAssertEqual(routeStatus(core.beginRoute(0)), .stale)
        XCTAssertEqual(controlKinds(&core, session: 1), [.focusGained, .stateReset])
        XCTAssertEqual(sourceRing.pop().recordOrStatus, .ok)
    }

    func testFocusedConsumerDeathPromotesPendingTarget() throws {
        let first = page(token: 84, epoch: 1)
        let second = page(token: 85, epoch: 1)
        defer {
            first.deallocate()
            second.deallocate()
        }
        var core = InputRouterCore()
        XCTAssertEqual(
            core.registerConsumer(
                0,
                binding: binding(1, 84, first)
            ).status,
            .ok
        )
        XCTAssertEqual(
            core.registerConsumer(
                1,
                binding: binding(2, 85, second)
            ).status,
            .ok
        )
        XCTAssertEqual(core.focusTarget(0), .pending)
        drainControls(&core, session: 0)
        XCTAssertEqual(core.focusTarget(1), .pending)

        let removed = core.sweepDeadIdentity(
            0,
            sourceAlive: true,
            pendingSourceAlive: true,
            consumerAlive: false
        )
        XCTAssertEqual(removed.first.identity, 1)
        XCTAssertEqual(
            controlKinds(&core, session: 1),
            [.focusGained, .stateReset]
        )
    }

    func testPendingTargetDeathKeepsCurrentFocus() throws {
        let current = page(token: 86, epoch: 1)
        let target = page(token: 87, epoch: 1)
        defer {
            current.deallocate()
            target.deallocate()
        }
        var core = InputRouterCore()
        XCTAssertEqual(
            core.registerConsumer(
                0,
                binding: binding(1, 86, current)
            ).status,
            .ok
        )
        XCTAssertEqual(
            core.registerConsumer(
                1,
                binding: binding(2, 87, target)
            ).status,
            .ok
        )
        XCTAssertEqual(core.focusTarget(0), .pending)
        drainControls(&core, session: 0)
        XCTAssertEqual(core.focusTarget(1), .pending)

        let removed = core.sweepDeadIdentity(
            1,
            sourceAlive: true,
            pendingSourceAlive: true,
            consumerAlive: false
        )
        XCTAssertEqual(removed.first.identity, 2)
        XCTAssertEqual(controlKinds(&core, session: 0), [])
    }

    func testFullConsumerRetainsPendingFocusNotifications() throws {
        let consumer = page(token: 91, epoch: 1)
        defer {
            consumer.deallocate()
        }
        var core = InputRouterCore()
        XCTAssertEqual(core.registerConsumer(0, binding: binding(1, 91, consumer)).status, .ok)
        let ring = try XCTUnwrap(ReixInputRing(page: consumer, token: 91, epoch: 1))
        fill(ring)
        XCTAssertEqual(core.focusTarget(0), .pending)
        XCTAssertEqual(routeStatus(core.beginRoute(0)), .full)
        _ = ring.pop()

        XCTAssertEqual(controlKinds(&core, session: 0), [.focusGained])
        _ = ring.pop()
        XCTAssertEqual(controlKinds(&core, session: 0), [.stateReset])
    }

    func testDeathReturnsAllBindingsAndFocusedReconnectResets() throws {
        let active = page(token: 101, epoch: 1)
        let pending = page(token: 102, epoch: 1)
        let consumer = page(token: 103, epoch: 1)
        let replacement = page(token: 104, epoch: 1)
        defer {
            active.deallocate()
            pending.deallocate()
            consumer.deallocate()
            replacement.deallocate()
        }
        var core = configured(source: active, consumer: consumer, sourceToken: 101, consumerToken: 103)
        XCTAssertEqual(core.stageSourceRing(0, binding: binding(3, 102, pending)).status, .ok)
        let removed = core.sweepDeadIdentity(
            0,
            sourceAlive: false,
            pendingSourceAlive: false,
            consumerAlive: false
        )
        XCTAssertEqual(removed.status, .ok)
        XCTAssertEqual([removed.first.identity, removed.second.identity, removed.third.identity], [1, 3, 2])

        XCTAssertEqual(core.focusTarget(0), .pending)
        XCTAssertEqual(core.registerConsumer(0, binding: binding(4, 104, replacement)).status, .ok)
        XCTAssertEqual(controlKinds(&core, session: 0), [.focusGained, .stateReset])
    }

    func testSequenceWrapNeverEmitsZeroOrAsynchronousValues() throws {
        let source = page(token: 111, epoch: 1)
        let consumer = page(token: 112, epoch: 1)
        defer {
            source.deallocate()
            consumer.deallocate()
        }
        var core = configured(source: source, consumer: consumer, sourceToken: 111, consumerToken: 112)
        drainControls(&core, session: 0)
        let sourceRing = try XCTUnwrap(ReixInputRing(page: source, token: 111, epoch: 1))
        core.setSequenceForTesting(ReixInteractionSequence.maximumCorrelated, session: 0)
        let input = try XCTUnwrap(ReixInputRecord(kind: .enter, sequence: 1))
        XCTAssertEqual(sourceRing.push(input), .ok)

        let plan = try dataPlan(&core, session: 0)
        XCTAssertEqual(plan.sequence, 1)
        XCTAssertNotEqual(plan.sequence, 0)
        XCTAssertLessThanOrEqual(plan.sequence, ReixInteractionSequence.maximumCorrelated)
        XCTAssertEqual(core.finishRoute(plan, callbackSucceeded: true), .ok)
    }

    func testDeadPendingSourceDoesNotReleaseLiveSource() {
        let source = page(token: 121, epoch: 1)
        let pending = page(token: 122, epoch: 1)
        defer {
            source.deallocate()
            pending.deallocate()
        }
        var core = InputRouterCore()
        XCTAssertEqual(core.stageSourceRing(0, binding: binding(1, 121, source)).status, .ok)
        XCTAssertEqual(core.commitSourceCallback(0, identity: 1, callback: 77).status, .ok)
        XCTAssertEqual(core.stageSourceRing(0, binding: binding(3, 122, pending)).status, .ok)

        let removed = core.sweepDeadIdentity(
            0,
            sourceAlive: true,
            pendingSourceAlive: false,
            consumerAlive: true
        )
        XCTAssertEqual(removed.status, .ok)
        XCTAssertEqual(removed.first.identity, 3)
        XCTAssertEqual(removed.second.identity, 0)
        XCTAssertEqual(core.sourceIdentity(0), 1)
        XCTAssertEqual(core.pendingSourceIdentity(0), 0)
    }

    func testDeadSourceDoesNotReleaseLivePendingSource() {
        let source = page(token: 131, epoch: 1)
        let pending = page(token: 132, epoch: 1)
        defer {
            source.deallocate()
            pending.deallocate()
        }
        var core = InputRouterCore()
        XCTAssertEqual(core.stageSourceRing(0, binding: binding(1, 131, source)).status, .ok)
        XCTAssertEqual(core.commitSourceCallback(0, identity: 1, callback: 77).status, .ok)
        XCTAssertEqual(core.stageSourceRing(0, binding: binding(3, 132, pending)).status, .ok)

        let removed = core.sweepDeadIdentity(
            0,
            sourceAlive: false,
            pendingSourceAlive: true,
            consumerAlive: true
        )
        XCTAssertEqual(removed.status, .ok)
        XCTAssertEqual(removed.first.identity, 1)
        XCTAssertEqual(removed.second.identity, 0)
        XCTAssertEqual(core.sourceIdentity(0), 0)
        XCTAssertEqual(core.pendingSourceIdentity(0), 3)
    }

    private func configured(
        source: UnsafeMutablePointer<UInt8>,
        consumer: UnsafeMutablePointer<UInt8>,
        sourceToken: UInt32,
        consumerToken: UInt32
    ) -> InputRouterCore {
        var core = InputRouterCore()
        XCTAssertEqual(core.stageSourceRing(0, binding: binding(1, sourceToken, source)).status, .ok)
        XCTAssertEqual(core.commitSourceCallback(0, identity: 1, callback: 77).status, .ok)
        XCTAssertEqual(core.registerConsumer(0, binding: binding(2, consumerToken, consumer)).status, .ok)
        XCTAssertEqual(core.focusTarget(0), .pending)
        drainControls(&core, session: 0)
        drainRecords(page: consumer, token: consumerToken)
        return core
    }

    private func dataPlan(_ core: inout InputRouterCore, session: Int) throws -> InputRoutePlan {
        guard case .plan(let plan) = core.beginRoute(session) else {
            throw TestError.missingRoutePlan
        }
        XCTAssertTrue(isData(plan.kind))
        return plan
    }

    private func controlKinds(_ core: inout InputRouterCore, session: Int) -> [ReixInputKind] {
        var kinds: [ReixInputKind] = []
        for _ in 0..<4 {
            guard case .plan(let plan) = core.beginRoute(session) else {
                break
            }
            guard plan.callback == 0 else {
                break
            }
            kinds.append(controlInputKind(plan.kind))
            XCTAssertEqual(core.finishRoute(plan, callbackSucceeded: true), .ok)
        }
        return kinds
    }

    private func drainControls(_ core: inout InputRouterCore, session: Int) {
        _ = controlKinds(&core, session: session)
    }

    private func drainRecords(page: UnsafeMutablePointer<UInt8>, token: UInt32) {
        guard let ring = ReixInputRing(page: page, token: token, epoch: 1) else {
            XCTFail("missing consumer ring")
            return
        }
        for _ in 0..<ReixInputRing.capacity {
            guard case .record = ring.pop() else {
                break
            }
        }
    }

    private func fill(_ ring: ReixInputRing) {
        for sequence in 1...ReixInputRing.capacity {
            XCTAssertEqual(ring.push(ReixInputRecord(kind: .enter, sequence: UInt32(sequence))!), .ok)
        }
    }

    private func record(from ring: ReixInputRing) throws -> ReixInputRecord {
        guard case .record(let record) = ring.pop() else {
            throw TestError.missingRecord
        }
        return record
    }

    private func routeStatus(_ start: InputRouteStart) -> ReixInputServerStatus? {
        guard case .status(let status) = start else {
            return nil
        }
        return status
    }

    private func isData(_ kind: InputRouteKind) -> Bool {
        if case .data = kind {
            return true
        }
        return false
    }

    private func controlInputKind(_ kind: InputRouteKind) -> ReixInputKind {
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

    private func consumerCursor(_ page: UnsafeMutablePointer<UInt8>) -> UInt32 {
        read32(page, offset: 32)
    }

    private func page(token: UInt32, epoch: UInt64) -> UnsafeMutablePointer<UInt8> {
        let result = UnsafeMutablePointer<UInt8>.allocate(capacity: ReixInputRing.pageBytes)
        XCTAssertTrue(ReixInputRing.initialize(page: result, token: token, epoch: epoch))
        return result
    }

    private func binding(_ identity: UInt32, _ token: UInt32, _ page: UnsafeMutablePointer<UInt8>) -> InputBinding {
        InputBinding(identity: identity, token: token, epoch: 1, page: page)
    }
}

private enum TestError: Error {
    case missingRoutePlan
    case missingRecord
}

private struct CursorPair: Equatable {
    let producer: UInt32
    let consumer: UInt32

    init(page: UnsafeMutablePointer<UInt8>) {
        producer = read32(page, offset: 28)
        consumer = read32(page, offset: 32)
    }
}

private func read32(_ page: UnsafeMutablePointer<UInt8>, offset: Int) -> UInt32 {
    UInt32(page[offset])
        | UInt32(page[offset + 1]) << 8
        | UInt32(page[offset + 2]) << 16
        | UInt32(page[offset + 3]) << 24
}

private extension ReixInputRingPop {
    var recordOrStatus: ReixInputServerStatus {
        switch self {
            case .record:
                return .ok
            case .status(let status):
                return status
        }
    }
}


private func run(_ name: String, _ body: () throws -> Void) {
    scenario = name
    do {
        try body()
    } catch {
        fail("unexpected error: \(error)")
    }
}

kernel_host_shims_link_anchor()
private let harness = InputRouterHarness()
run("input access round trip and invalid words", harness.testInputAccessRoundTripAndRejectsInvalidWords)
run("source record reaches consumer", harness.testRoutesSourceRecordToConsumerWithExactFields)
run("full consumer retains source", harness.testFullConsumerDoesNotConsumeSource)
run("malformed source retains cursor", harness.testMalformedSourceDoesNotAdvanceCursorAcrossRetries)
run("callback failure retains source", harness.testCallbackFailureDoesNotConsumeSource)
run("token and epoch corruption", harness.testTokenAndEpochCorruptionReturnStaleWithoutCursorMovement)
run("source stage and commit", harness.testSourceStagePreservesActiveAndCommitReturnsOldBinding)
run("focus before consumer", harness.testFocusBeforeConsumerDeliversGainedThenReset)
run("focus transfer ordering", harness.testFocusTransferOrdersControlsAndBlocksDataDuringTransition)
run("focused consumer death", harness.testFocusedConsumerDeathPromotesPendingTarget)
run("pending focus death", harness.testPendingTargetDeathKeepsCurrentFocus)
run("full consumer focus notifications", harness.testFullConsumerRetainsPendingFocusNotifications)
run("death and focused reconnect", harness.testDeathReturnsAllBindingsAndFocusedReconnectResets)
run("sequence wrap", harness.testSequenceWrapNeverEmitsZeroOrAsynchronousValues)
run("dead pending source retains live source", harness.testDeadPendingSourceDoesNotReleaseLiveSource)
run("dead source retains live pending source", harness.testDeadSourceDoesNotReleaseLivePendingSource)

if failures == 0 {
    print("InputRouterHarness passed \(checks) checks")
} else {
    print("InputRouterHarness failed \(failures) of \(checks) checks")
    exit(code: 1)
}
