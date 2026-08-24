//
//  BlockDurability.swift
//  ReixOS
//
//  Created by Eliomar on 23/08/2026.
//


/// What a write on a device has actually achieved when its request comes back.
///
/// Three things get called "written" and they are not synonyms. Naming them
/// apart is the point of this type existing, because a file system with no
/// journal has nothing but these to build crash safety out of:
///
/// - **completed**: the device has taken the request and answered it. Every
///   device does this, and on its own it promises nothing about a power cut.
/// - **ordered**: this write cannot reach the medium after a write issued later.
///   That is what `flush` buys between two groups of writes, and what
///   `FileSystem.barrier` asks for.
/// - **durable**: the bytes survive the machine losing power. That is what
///   `flush` buys for everything issued before it.
///
/// A device is one of two kinds, and it says which. Guessing is what a driver
/// does when the layer above never asked, and guessing wrong in the cheap
/// direction is a file system that believes an order it never had.
public enum BlockDurability: Equatable {

    /// A write is on the medium by the time its request completes.
    ///
    /// There is nothing to flush, so ordering is free: the completions are the
    /// order. Memory standing in for a disk is like this, and so is any device
    /// that told the transport it keeps no volatile write cache.
    case onCompletion

    /// A write is *accepted* when its request completes, and on the medium when
    /// a later `flush` completes.
    ///
    /// The ordinary case for a real disk. Completion here says the device has
    /// the bytes, not that the medium does, and nothing is ordered against
    /// anything until a flush lands between them.
    case onFlush
}
