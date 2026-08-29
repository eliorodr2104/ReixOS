//
//  Terminal.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// A client of the semantic InputServer/TextSurface transport.
///
/// This client owns exactly two pages: InputServer writes page zero and the
/// shell reads it; the shell writes TextSurface commands on page one and the
/// server reads them. UART bytes and VT escape bytes never cross this boundary.
public struct Terminal: ~Copyable {
    private let endpoint: UInt32
    private let handle: UInt32
    private let address: UInt64
    private let token: UInt32
    private let epoch: UInt64
    private var sequence: UInt32 = 0
    private var usable = true

    private var inputPage: UnsafeMutablePointer<UInt8> {
        UnsafeMutableRawPointer(bitPattern: UInt(address))!.assumingMemoryBound(to: UInt8.self)
    }

    private var surfacePage: UnsafeMutablePointer<UInt8> {
        inputPage.advanced(by: ReixTerminalTransport.pageBytes)
    }

    public init?(endpoint: UInt32) {
        let shared = shmCreate(pageCount: UInt64(ReixTerminalTransport.pages))
        guard shared.isValid, shared.handle != 0,
              let page = UnsafeMutableRawPointer(bitPattern: UInt(shared.address))?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let token = shared.handle
        func giveUp() {
            _ = munmap(addr: shared.address, size: UInt64(ReixTerminalTransport.regionBytes))
            _ = capDrop(shared.handle)
        }
        guard ReixTerminalRing.initialize(page: page, role: .input, token: token),
              ReixTerminalRing.initialize(page: page.advanced(by: ReixTerminalTransport.pageBytes), role: .surface, token: token)
        else { giveUp(); return nil }
        _ = send(
            handle: endpoint,
            message: TerminalOperation.register.message(word0: UInt32(ReixTerminalTransport.pages), word1: token),
            grant: shared.handle,
            grantRights: [.send, .read, .write]
        )
        guard case .success(let answer) = call(handle: endpoint, message: TerminalOperation.status.message(word0: token)),
              answer.message.tag.length == 4,
              TerminalStatus(rawValue: answer.message.words[0]) == .ok,
              answer.message.words[1] == token
        else { giveUp(); return nil }
        let epoch = UInt64(answer.message.words[2]) | UInt64(answer.message.words[3]) << 32
        guard epoch != 0,
              ReixTerminalRing(page: page, role: .input, token: token, epoch: epoch) != nil,
              ReixTerminalRing(page: page.advanced(by: ReixTerminalTransport.pageBytes), role: .surface, token: token, epoch: epoch) != nil
        else { giveUp(); return nil }
        self.endpoint = endpoint
        self.handle = shared.handle
        self.address = shared.address
        self.token = token
        self.epoch = epoch
    }

    deinit {
        _ = munmap(addr: address, size: UInt64(ReixTerminalTransport.regionBytes))
        _ = capDrop(handle)
    }

    public mutating func readInput() -> ReixInputRecord? {
        guard usable else { return nil }
        sequence = ReixTerminalTransport.nextCorrelatedSequence(after: sequence)
        let current = sequence
        guard case .success(let answer) = call(handle: endpoint, message: message(.awaitInput, sequence: current)),
              answer.message.tag.label == TerminalOperation.awaitInput.rawValue,
              answer.message.tag.length == 4,
              TerminalStatus(rawValue: answer.message.words[0]) == .ok,
              answer.message.words[1] == current,
              answer.message.words[2] == token,
              answer.message.words[3] == UInt32(truncatingIfNeeded: epoch),
              let ring = ReixTerminalRing(page: inputPage, role: .input, token: token, epoch: epoch),
              let event = ring.popInput(sequence: current)
        else { usable = false; return nil }
        return event
    }

    public mutating func present(_ command: ReixTextSurfaceCommand) -> Bool {
        guard usable, command.sequence != 0 else { return false }
        guard let ring = ReixTerminalRing(page: surfacePage, role: .surface, token: token, epoch: epoch),
              ring.push(command)
        else { usable = false; return false }
        guard case .success(let answer) = call(handle: endpoint, message: message(.present, sequence: command.sequence)),
              answer.message.tag.label == TerminalOperation.present.rawValue,
              answer.message.tag.length == 4,
              TerminalStatus(rawValue: answer.message.words[0]) == .ok,
              answer.message.words[1] == command.sequence,
              answer.message.words[2] == token,
              answer.message.words[3] == UInt32(truncatingIfNeeded: epoch)
        else { usable = false; return false }
        return true
    }

    private func message(_ operation: TerminalOperation, sequence: UInt32) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = sequence
        words[1] = token
        words[2] = UInt32(truncatingIfNeeded: epoch)
        words[3] = UInt32(truncatingIfNeeded: epoch >> 32)
        return Message(tag: MessageTag(operation, length: 4), words: words)
    }
}
