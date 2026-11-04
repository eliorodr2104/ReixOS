//
//  Environment.swift
//  ReixOS
//
//

import ReixABI

public struct Environment {

    private var slots          : InlineArray<24, UInt32?>
    private var readinessParent: UInt32?
    private var readinessNonce : UInt32

    public var parentEndpoint: UInt32? { handle(.parentEndpoint) }
    public var console       : UInt32? { handle(.console) }
    public var nameServer    : UInt32? { handle(.nameServer) }
    public var spawn         : UInt32? { handle(.spawn) }
    public var device        : UInt32? { handle(.device) }
    public var profiler      : UInt32? { handle(.profiler) }
    public var profileMarker : UInt32? { handle(.profileMarker) }

    /// The interrupt lines this process may wait on, if its spawner granted
    /// any. One handle names a whole set: see `irqWait`.
    public var interrupt: UInt32? { handle(.interrupt) }

    /// The terminal this process reads lines from, if it was given one.
    public var terminal      : UInt32? { handle(.terminal) }
    public var inputSource   : UInt32? { handle(.inputSource) }
    public var inputConsumer : UInt32? { handle(.inputConsumer) }
    public var inputFocus    : UInt32? { handle(.inputFocus) }
    public var serialReader  : UInt32? { handle(.serialReader) }
    public var serialWriter  : UInt32? { handle(.serialWriter) }
    public var programs      : UInt32? { handle(.programs) }
    public var processServer : UInt32? { handle(.processServer) }
    public var sessionControl: UInt32? { handle(.sessionControl) }

    /// The virtio bus, for the process that probes it and hands out what it
    /// finds. Not a window and not a line: the right to carve one.
    public var virtioBus: UInt32? { handle(.virtioBus) }

    /// The container of the disk this process may see, if it was given one.
    ///
    /// `nil` is the normal answer. A view of the disk is something a parent
    /// decides to pass down, and a process that was passed none cannot look one
    /// up: the file system publishes no name.
    public var container: UInt32? { handle(.container) }

    /// A piece of somebody else's container this process was let into.
    public var shared: UInt32? { handle(.shared) }

    /// The disk this process may reach, if it was handed one.
    ///
    /// `nil` for everybody but the file system and whoever was given a
    /// read-only view for looking. Which of the two this is cannot be read off
    /// the handle here: it is the badge the server sees, and the server is what
    /// enforces it.
    public var block: UInt32? { handle(.block) }

    /// The Name Server capability this process may *register* through, if its
    /// spawner granted it one. `nameServer` resolves names for everybody; this
    /// one is the badged capability that also publishes them.
    public var nameServerRegistrar: UInt32? { handle(.nameServerRegistrar) }


    private init(
        slots          : InlineArray<24, UInt32?>,
        readinessParent: UInt32? = nil,
        readinessNonce : UInt32 = 0
    ) {
        self.slots = slots
        self.readinessParent = readinessParent
        self.readinessNonce = readinessNonce
    }

    public init(
        console      : UInt32?,
        nameServer   : UInt32?,
        spawn        : UInt32?,
        device       : UInt32? = nil,
        profiler     : UInt32? = nil,
        profileMarker: UInt32? = nil,
        serialReader : UInt32? = nil,
        serialWriter : UInt32? = nil
    ) {

        self.slots = InlineArray<24, UInt32?>(repeating: nil)
        self.readinessParent = nil
        self.readinessNonce = 0

        self.slots[Int(BootCap.console.rawValue)]       = console
        self.slots[Int(BootCap.nameServer.rawValue)]    = nameServer
        self.slots[Int(BootCap.spawn.rawValue)]         = spawn
        self.slots[Int(BootCap.device.rawValue)]        = device
        self.slots[Int(BootCap.profiler.rawValue)]      = profiler
        self.slots[Int(BootCap.profileMarker.rawValue)] = profileMarker
        self.slots[Int(BootCap.serialReader.rawValue)]  = serialReader
        self.slots[Int(BootCap.serialWriter.rawValue)]  = serialWriter

    }

    public static func boot() -> Environment {
        var slots            = InlineArray<24, UInt32?>(repeating: nil)
        var hasLegacyBinding = false

        for i in 0..<slots.count {
            let handle = UInt32(i)
            if capExists(handle) {
                slots[i] = handle
                if i != Int(BootCap.parentEndpoint.rawValue) {
                    hasLegacyBinding = true
                }
            }
        }

        guard !hasLegacyBinding,
              let parent = slots[Int(BootCap.parentEndpoint.rawValue)]
        else {
            return Environment(slots: slots)
        }

        return dynamicBoot(parent: parent, initial: slots)
    }

    @inline(__always)
    public func handle(_ cap: BootCap) -> UInt32? {
        guard Int(cap.rawValue) < slots.count else { return nil }
        return slots[Int(cap.rawValue)]
    }


    /// Commit application-level readiness after mandatory runtime resources
    /// have been opened. Legacy bootstrap services have no pending transaction
    /// and therefore succeed without sending anything.
    public mutating func signalReady() -> Bool {
        guard let parent = readinessParent else { return true }

        guard send(
            handle : parent,
            message: EnvironmentTransaction.ready(nonce: readinessNonce)
        ).isDelivered else { return false }

        readinessParent = nil
        readinessNonce = 0
        return true
    }


    /// Receive an all-or-nothing semantic environment from ProcessServer.
    /// Handles may land in any free capability slot; only the binding carried
    /// by the transaction gives them meaning.
    private static func dynamicBoot(
        parent : UInt32,
        initial: InlineArray<24, UInt32?>
    ) -> Environment {
        var slots         = initial
        var received      = InlineArray<16, UInt32?>(repeating: nil)
        var receivedCount = 0

        func discardReceived() {
            for index in 0..<receivedCount {
                if let handle = received[index] { _ = capDrop(handle) }
            }
        }

        let begin = receive(handle: parent)
        guard begin.status == .ok,
              begin.message.tag.label == EnvironmentTransactionOperation.begin.rawValue,
              begin.message.tag.length == 3,
              begin.grantedCap == nil,
              begin.message.words[0] == EnvironmentTransaction.version,
              begin.message.words[1] <= EnvironmentTransaction.maximumBindings
        else {
            _ = send(handle: parent, message: EnvironmentTransaction.refused(nonce: 0))
            return Environment(slots: slots)
        }

        let count = Int(begin.message.words[1])
        let nonce = begin.message.words[2]

        guard send(
            handle : parent,
            message: EnvironmentTransaction.acknowledgement(
                index: UInt32.max,
                nonce: nonce
            )
        ).isDelivered else {
            return Environment(slots: slots)
        }

        for index in 0..<count {
            var item = receive(handle: parent)

            guard item.status == .ok,
                  item.message.tag.label == EnvironmentTransactionOperation.binding.rawValue,
                  item.message.tag.length == 3,
                  item.message.words[1] == UInt32(index),
                  item.message.words[2] == nonce,
                  let binding  = EnvironmentBinding(rawValue: item.message.words[0]),
                  let semantic = BootCap(rawValue: binding.rawValue),
                  slots[Int(semantic.rawValue)] == nil
            else {
                if let stray = item.takeGrant() { _ = capDrop(stray) }
                discardReceived()
                _ = send(handle: parent, message: EnvironmentTransaction.refused(nonce: nonce))
                return Environment(slots: initial)
            }

            guard let handle = item.takeGrant() else {
                discardReceived()
                _ = send(handle: parent, message: EnvironmentTransaction.refused(nonce: nonce))
                return Environment(slots: initial)
            }

            slots[Int(semantic.rawValue)] = handle
            received[receivedCount] = handle
            receivedCount += 1

            guard send(
                handle : parent,
                message: EnvironmentTransaction.acknowledgement(
                    index: UInt32(index),
                    nonce: nonce
                )
            ).isDelivered else {
                discardReceived()
                return Environment(slots: initial)
            }
        }

        let commit = receive(handle: parent)
        guard commit.status == .ok,
              commit.message.tag.label == EnvironmentTransactionOperation.commit.rawValue,
              commit.message.tag.length == 1,
              commit.message.words[0] == nonce,
              commit.grantedCap == nil
        else {
            discardReceived()
            _ = send(handle: parent, message: EnvironmentTransaction.refused(nonce: nonce))
            return Environment(slots: initial)
        }

        return Environment(
            slots: slots,
            readinessParent: parent,
            readinessNonce: nonce
        )
    }

}
