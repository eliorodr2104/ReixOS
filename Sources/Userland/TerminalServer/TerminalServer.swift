//
//  TerminalServer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import Reix
import ReixABI

/// Owns the keyboard and turns keystrokes into lines.
///
/// The line discipline of this system: echo, erase, and the decision that a
/// carriage return ends a line. It lives here and not in the shell for the same
/// reason it lives in the kernel on a BSD: it is a property of the terminal, and
/// every program that reads from one should get the same editing without
/// implementing it.
///
/// **One reader at a time, on purpose.** A `readLine` runs the editor inside the
/// request, so while it is in progress this server answers nobody else. That is
/// what lets it exist with no way to wait on an endpoint and an interrupt at
/// once: a second reader queues behind the first, which is what a terminal
/// should do anyway. The kernel primitive for waiting on both is what a second
/// *terminal* would need, and it is still not needed.
///
/// It holds the serial window and the interrupt line, and nothing else holds
/// them. A shell that wanted to read the keyboard directly could not: it has no
/// device capability to map.
public struct TerminalServer: Service {

    public static let manifest = ServiceManifest(provides: .parent)

    private let endpoint : UInt32
    private let uartBase : UnsafeMutableRawPointer
    private let interrupt: UInt32

    /// The one registered reader: who it is, and the page its lines land in.
    private var readerBadge: UInt32 = 0
    private var readerPage : UnsafeMutableRawPointer?

    /// Lines the kernel delivered and masked, owed back after the device is
    /// serviced.
    private var delivered: UInt64 = 0

    public var serviceEndpoint: UInt32 { endpoint }


    public init(
        environment: Environment,
        endpoint   : UInt32
    ) {
        self.endpoint = endpoint

        guard let device = environment.device, let interrupt = environment.interrupt else {
            print("[ SERVE ] Terminal Server has no terminal capabilities")
            exit(code: 1)
        }

        guard let mapped = UnsafeMutableRawPointer(
            bitPattern: UInt(mapDevice(handle: device))
        ) else {
            print("[ SERVE ] Terminal Server cannot map the serial window")
            exit(code: 1)
        }

        self.uartBase  = mapped
        self.interrupt = interrupt

        pl011EnableReceive(mapped)

        print("[ SERVE ] Terminal Server running")
    }


    public mutating func handle(
        _ operation: TerminalOperation,
          request  : inout ReceivedMessage
    ) {
        switch operation {
            case .register: register(&request)
            case .status  : status(&request)
            case .readLine: readLine(&request)
        }
    }


    /// Takes the page a client granted and remembers whose it is.
    ///
    /// Keyed on the badge the kernel put on the message, never on anything the
    /// client said about itself, so nobody can register a page in another
    /// reader's name.
    private mutating func register(_ request: inout ReceivedMessage) {
        let badge = request.identity

        // No reply on this path: the request carried a capability, and a message
        // that carries one is a send. The caller asks `status` afterwards.
        guard badge != 0, let granted = request.takeGrant() else { return }

        guard let mapped = UnsafeMutableRawPointer(
            bitPattern: UInt(shmMap(handle: granted))
        ) else { return }

        readerBadge = badge
        readerPage  = mapped
    }


    /// Whether the caller is the registered reader.
    private mutating func status(_ request: inout ReceivedMessage) {
        let known = request.identity == readerBadge && readerPage != nil

        _ = reply(message: TerminalOperation.status.message(
            word0: known ? TerminalStatus.ok.rawValue : TerminalStatus.unregistered.rawValue
        ))
    }


    /// Runs the editor until a line closes, then answers its length.
    private mutating func readLine(_ request: inout ReceivedMessage) {
        guard request.identity == readerBadge, let page = readerPage else {
            _ = reply(message: TerminalOperation.readLine.message(word0: UInt32.max))
            return
        }

        let bytes = page.assumingMemoryBound(to: UInt8.self)

        // The prompt arrived in the same page the line goes back in, and is
        // written before the editor overwrites it.
        let promptLength = min(Int(request.message.words[0]), Terminal.lineLimit)
        for index in 0..<promptLength { putchar(ch: bytes[index]) }
        consoleFlush()

        let count = edit(into: bytes)

        _ = reply(message: TerminalOperation.readLine.message(word0: UInt32(count)))
    }


    /// The editor: keystrokes in, one line out.
    private mutating func edit(into line: UnsafeMutablePointer<UInt8>) -> Int {

        var count = 0

        while true {
            // Drain first and wait second, always: keys pressed before this
            // call, or between the last drain and the mask, are already in the
            // FIFO and no interrupt is coming to announce them.
            while true {
                let read = pl011TryReadByte(uartBase)
                guard read != Self.fifoEmpty else { break }

                switch UInt8(truncatingIfNeeded: read) {
                    case Self.carriageReturn, Self.lineFeed:
                        putchar(ch: Self.lineFeed)
                        consoleFlush()

                        return count

                    case Self.delete, Self.backspace:
                        guard count > 0 else { break }
                        count -= 1
                        erase()

                    case let byte where byte >= 0x20 && byte < Self.delete:
                        guard count < Terminal.lineLimit else { break }
                        line[count] = byte
                        count += 1

                        putchar(ch: byte)
                        consoleFlush()

                    default:
                        break // Control characters this terminal has no meaning for yet.
                }
            }

            // Acknowledge at the device before unmasking at the controller, or
            // the same condition raises the line again the moment it is armed.
            pl011ClearReceive(uartBase)

            if delivered != 0 {
                _ = irqAck(handle: interrupt, bits: delivered)
                delivered = 0
            }

            let fired = irqWait(handle: interrupt)
            guard fired != UInt64.max else { return count }

            delivered = fired
        }
    }


    /// Backspace, space, backspace: the character is painted out, which is what
    /// a terminal that cannot address the cursor has to do.
    private func erase() {
        putchar(ch: Self.backspace)
        putchar(ch: 0x20)
        putchar(ch: Self.backspace)

        consoleFlush()
    }


    private static let fifoEmpty     : UInt32 = 0x100
    private static let carriageReturn: UInt8  = 0x0D
    private static let lineFeed      : UInt8  = 0x0A
    private static let backspace     : UInt8  = 0x08
    private static let delete        : UInt8  = 0x7F
}
