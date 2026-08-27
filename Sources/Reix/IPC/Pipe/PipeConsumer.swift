//
//  PipeConsumer.swift
//  ReixOS
//
//  Created by Eliomar on 24/08/2026.
//


public struct PipeConsumer: ~Copyable {

    private static let (extent, overflow) = UInt64(Pipe.pages)
        .multipliedReportingOverflow(by: Pipe.pageSize)

    private let endpoint: UInt32

    private var attachment = ShmAttachment.Slot()
    private var state      = PipeTransferState()

    public init(on endpoint: UInt32) {
        self.endpoint = endpoint
    }

    deinit {
        if let held = attachment.current { release(held) }
    }

    @inline(__always)
    private func release(_ held: ShmAttachment) {
        _ = munmap(addr: held.address, size: held.extent)
        _ = capDrop(held.grant)
    }

    public mutating func close() {
        if let held = attachment.take() { release(held) }
        state.detach()
    }

    private mutating func receiveOpen(_ request: inout ReceivedMessage) {

        guard request.message.tag.length == 2,
              request.message.words[0] == UInt32(Pipe.pages),
              request.message.words[1] != 0,
              state.acceptsAttachment(identity: request.identity)

        else {
            if let granted = request.takeGrant() { _ = capDrop(granted) }
            return
        }

        guard let granted = request.takeGrant() else { return }

        guard shmPages(handle: granted) == UInt32(Pipe.pages),
              ShmAttachment.accepts(
                pages : UInt32(Pipe.pages),
                atMost: UInt32(Pipe.pages)
              ),
              let epoch = attachment.nextEpoch()

        else {
            _ = capDrop(granted)
            return
        }

        let address = shmMap(handle: granted)
        guard address != 0 else {
            _ = capDrop(granted)
            return
        }

        guard !Self.overflow else {
            _ = munmap(addr: address, size: Pipe.pages * Pipe.pageSize)
            _ = capDrop(granted)
            return
        }

        guard state.attach(
            identity: request.identity,
            token   : request.message.words[1]

        ) else {
            _ = munmap(addr: address, size: Self.extent)
            _ = capDrop(granted)
            return
        }

        let displaced = attachment.install(
            ShmAttachment(
                identity: request.identity,
                epoch   : epoch,
                address : address,
                extent  : Self.extent,
                grant   : granted
            )
        )

        if let displaced { release(displaced) }
    }

    @inline(__always)
    private func acknowledge(
        _ frame : PipeFrame,
        _ status: PipeStatus
    ) {

        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = status == .ok ? frame.count : 0
        words[1] = status.rawValue
        words[2] = status == .ok ? frame.flags : 0
        words[3] = status == .ok ? frame.token : 0

        _ = reply(
            message: Message(
                tag  : MessageTag(PipeOperation.frame, length: 4),
                words: words
            )
        )
    }

    public mutating func take(
        into destination: UnsafeMutableRawPointer,
             capacity   : Int
    ) -> PipeTake {

        while true {

            var request = Reix.receive(handle: endpoint)
            guard request.arrived else { return PipeTake(.transportFailed) }

            switch PipeOperation(rawValue: request.message.tag.label) {
                case .open: receiveOpen(&request)

                case .frame:
                    guard request.message.tag.length == 3,
                          request.grantedCap == nil else {

                        if let granted = request.takeGrant() { _ = capDrop(granted) }

                        let frame = PipeFrame(
                            rawCount: 0,
                            flags   : 0,
                            token   : request.message.words[2]
                        )

                        acknowledge(frame, .invalidFrame)
                        return PipeTake(.invalidFrame)
                    }

                    let frame = PipeFrame(
                        rawCount: request.message.words[0],
                        flags   : request.message.words[1],
                        token   : request.message.words[2]
                    )

                    guard let held = attachment.current else {
                        acknowledge(frame, .noAttachment)
                        return PipeTake(.noAttachment)
                    }

                    let status = state.checked(
                        frame,
                        identity           : request.identity,
                        token              : frame.token,
                        extent             : held.extent,
                        destinationCapacity: capacity
                    )

                    if status == .ok, frame.count > 0,
                       let source = UnsafeRawPointer(bitPattern: UInt(held.address)) {
                        destination.copyMemory(from: source, byteCount: Int(frame.count))
                    }

                    acknowledge(frame, status)

                    if status == .ok, frame.ends { close() }

                    return PipeTake(
                        status,
                        status == .ok ? Int(frame.count) : 0,
                        ended: status == .ok && frame.ends
                    )

                case nil:
                    if let granted = request.takeGrant() { _ = capDrop(granted) }
            }
        }
    }
}
