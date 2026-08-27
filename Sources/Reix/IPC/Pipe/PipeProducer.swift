//
//  PipeProducer.swift
//  ReixOS
//
//  Created by Eliomar on 24/08/2026.
//

import ReixABI

public struct PipeProducer: ~Copyable {

    private static let totalPagesSize = Pipe.pages * Pipe.pageSize

    private let endpoint: UInt32
    private let page    : UnsafeMutableRawPointer
    private let address : UInt64
    private let shared  : UInt32
    private let token   : UInt32
    private var live    : Bool = true

    public init?(to endpoint: UInt32) {

        let region = shmCreate(pageCount: Pipe.pages)
        guard region.isValid,
              let page = UnsafeMutableRawPointer(bitPattern: UInt(region.address))

        else {
            if region.isValid {
                _ = munmap(addr: region.address, size: Self.totalPagesSize)
                _ = capDrop(region.handle)
            }
            return nil
        }

        var words = InlineArray<4, UInt32>(repeating: 0)
        guard region.handle != 0 else {
            _ = munmap(addr: region.address, size: Self.totalPagesSize)
            _ = capDrop(region.handle)
            return nil
        }
        words[0] = UInt32(Pipe.pages)
        words[1] = region.handle

        guard Reix.send(
            handle : endpoint,
            message: Message(tag: MessageTag(PipeOperation.open, length: 2), words: words),
            grant      : region.handle,
            grantRights: [.read, .write]

        ) == .ok else {
            _ = munmap(addr: region.address, size: Self.totalPagesSize)
            _ = capDrop(region.handle)
            return nil
        }

        self.endpoint = endpoint
        self.page     = page
        self.address  = region.address
        self.shared   = region.handle
        self.token    = region.handle
    }

    deinit {
        if live {
            _ = munmap(addr: address, size: Self.totalPagesSize)
            _ = capDrop(shared)
        }
    }

    @inline(__always)
    public mutating func close() {

        guard live else { return }

        live = false
        _ = munmap(addr: address, size: Self.totalPagesSize)
        _ = capDrop(shared)
    }

    private mutating func send(_ frame: PipeFrame) -> PipeStatus {
        guard live else { return .ended }

        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = frame.count
        words[1] = frame.flags
        words[2] = frame.token

        guard case .success(let answer) = call(
            handle: endpoint,
            message: Message(tag: MessageTag(PipeOperation.frame, length: 3), words: words)
        ), answer.message.tag.label == PipeOperation.frame.rawValue,
           answer.message.tag.length == 4,
           let status = PipeStatus(rawValue: answer.message.words[1])
        else { return .transportFailed }

        let acknowledgement = PipeAcknowledgement(
            count: answer.message.words[0],
            status: status,
            flags: answer.message.words[2],
            token: answer.message.words[3]
        )

        guard acknowledgement.accepts(frame) else {
            return status == .ok ? .acknowledgementMismatch : status
        }
        return .ok
    }

    public mutating func offer(
        _ bytes: UnsafeRawPointer,
          count: Int
    ) -> PipeStatus {

        guard let frame = PipeFrame(count: count, flags: 0, token: token),
                  count <= Pipe.capacity else {
            return .outOfBounds
        }

        page.copyMemory(from: bytes, byteCount: count)
        return send(frame)
    }

    public mutating func finish() -> PipeStatus {
        guard let end = PipeFrame(count: 0, flags: PipeFrame.endFlag, token: token) else {
            close()
            return .invalidFrame
        }

        let status = send(end)
        close()

        return status
    }

    public mutating func pump(
        _ next: (UnsafeMutableRawPointer, Int) -> PipeFill
    ) -> PipeStatus {

        while live {
            let filled = next(page, Pipe.capacity)
            guard filled.status == .ok else {
                close()
                return filled.status
            }

            guard filled.count >= 0, filled.count <= Pipe.capacity else {
                close()
                return .outOfBounds
            }

            guard filled.count > 0 else { return finish() }

            guard let frame = PipeFrame(count: filled.count, flags: 0, token: token) else {
                close()
                return .outOfBounds
            }
            let status = send(frame)
            guard status == .ok else {
                close()
                return status
            }
        }

        return .ended
    }
}
