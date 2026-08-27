//
//  KernelInterrupt.swift
//  ReixOS
//
//  Created by Eliomar on 24/08/2026.
//


/// An interrupt the kernel delivered, and the proof that it did.
///
/// A value only `ReceivedMessage.kernelInterrupt` can make, and that is the
/// whole of it: a driver cannot call its interrupt handler without one of these,
/// and cannot get one without having been handed a message the kernel wrote. The
/// origin check and the call to the handler are therefore the same statement, and
/// a driver written later cannot skip the first and keep the second.
///
/// It used to be a bare `UInt32` of lines read straight off a message whose only
/// credential was its label - which any process holding a capability to the
/// endpoint could stamp on anything.
public struct KernelInterrupt {

    /// The lines that fired, as bits over the holder's own line list.
    public let lines: UInt32

    internal init(lines: UInt32) {
        self.lines = lines
    }
}
