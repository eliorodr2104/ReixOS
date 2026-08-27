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
/// Three answers and not two, because there are two ways of being able to
/// promise something and one of not being able to promise anything, and the
/// third used to be spelled as the cheapest of the other two. A device that
/// never offered a way to empty its cache was read as a device that has no
/// cache, which is the transport's own reading of the virtio feature bit and
/// not a fact about the machine underneath it - and reading it that way turned
/// the absence of a guarantee into the strongest guarantee on the list.
public enum BlockDurability: UInt32, Equatable {

    /// Nothing is known about what a completed write has achieved.
    ///
    /// Not a middle setting: it is the absence of a claim, and every caller that
    /// needs an order has to refuse it rather than pick whichever of the other
    /// two suits. Nobody writing a file system may write a byte through one of
    /// these, because there is no sequence of requests on it that survives a
    /// power cut in a known state.
    case unknown = 0

    /// A write is on the medium by the time its request completes.
    ///
    /// There is nothing to flush, so ordering is free: the completions are the
    /// order. Memory standing in for a disk is like this. A real device gets to
    /// say it only by saying it - a driver may not infer it from a feature the
    /// device declined to offer.
    case onCompletion = 1

    /// A write is *accepted* when its request completes, and on the medium when
    /// a later `flush` completes.
    ///
    /// The ordinary case for a real disk. Completion here says the device has
    /// the bytes, not that the medium does, and nothing is ordered against
    /// anything until a flush lands between them.
    case onFlush = 2
}
