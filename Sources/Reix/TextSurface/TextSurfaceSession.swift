//
//  TextSurfaceSession.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

import ReixABI

/// The shell owns one TextSurface page and rings the presentation doorbell.
public struct TextSurfaceSession: ~Copyable {
    private let endpoint: UInt32
    private let handle: UInt32
    private let address: UInt64
    private let token: UInt32
    private let epoch: UInt64
    private var usable = true

    public init?(endpoint: UInt32) {
        let shared = shmCreate(pageCount: UInt64(ReixTextSurfaceTransport.pages))
        guard shared.isValid,
              shared.handle != 0,
              let page = UnsafeMutableRawPointer(bitPattern: UInt(shared.address))?.assumingMemoryBound(to: UInt8.self)
        else {
            return nil
        }
        let token = shared.handle
        func giveUp() {
            _ = munmap(addr: shared.address, size: UInt64(ReixTextSurfaceTransport.regionBytes))
            _ = capDrop(shared.handle)
        }
        guard ReixTextSurfaceRing.initialize(page: page, token: token) else {
            giveUp()
            return nil
        }
        _ = send(
            handle: endpoint,
            message: ReixTextSurfaceOperation.register.message(
                word0: UInt32(ReixTextSurfaceTransport.pages),
                word1: token
            ),
            grant: shared.handle,
            grantRights: [.send, .read, .write]
        )
        guard case .success(let answer) = call(
            handle: endpoint,
            message: ReixTextSurfaceOperation.status.message(word0: token)
        ),
              answer.message.tag.length == 4,
              ReixTextSurfaceStatus(rawValue: answer.message.words[0]) == .ok,
              answer.message.words[1] == token
        else {
            giveUp()
            return nil
        }
        let epoch = UInt64(answer.message.words[2]) | UInt64(answer.message.words[3]) << 32
        guard epoch != 0,
              ReixTextSurfaceRing(page: page, token: token, epoch: epoch) != nil
        else {
            giveUp()
            return nil
        }
        self.endpoint = endpoint
        self.handle = shared.handle
        self.address = shared.address
        self.token = token
        self.epoch = epoch
    }

    deinit {
        _ = munmap(addr: address, size: UInt64(ReixTextSurfaceTransport.regionBytes))
        _ = capDrop(handle)
    }

    public mutating func present(_ command: ReixTextSurfaceCommand) -> Bool {
        guard usable,
              command.sequence != 0,
              let page = UnsafeMutableRawPointer(bitPattern: UInt(address))?.assumingMemoryBound(to: UInt8.self),
              let ring = ReixTextSurfaceRing(page: page, token: token, epoch: epoch),
              ring.push(command)
        else {
            usable = false
            return false
        }
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = command.sequence
        words[1] = token
        words[2] = UInt32(truncatingIfNeeded: epoch)
        words[3] = UInt32(truncatingIfNeeded: epoch >> 32)
        guard case .success(let answer) = call(
            handle: endpoint,
            message: Message(
                tag: MessageTag(ReixTextSurfaceOperation.present, length: 4),
                words: words
            )
        ),
              answer.message.tag.label == ReixTextSurfaceOperation.present.rawValue,
              answer.message.tag.length == 4,
              ReixTextSurfaceStatus(rawValue: answer.message.words[0]) == .ok,
              answer.message.words[1] == command.sequence,
              answer.message.words[2] == token,
              answer.message.words[3] == UInt32(truncatingIfNeeded: epoch)
        else {
            usable = false
            return false
        }
        return true
    }
}
