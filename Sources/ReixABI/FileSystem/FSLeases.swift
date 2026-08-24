//
//  FSLeases.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

/// Who is in the middle of changing what.
///
/// An **application** lock, and not a transaction. What survives a power cut is
/// the write order and the barrier that makes it real; what this does is keep
/// one client's several requests from having another client's single one land in
/// the middle. It lives in memory and it goes away with the server, which is the
/// honest lifetime for the thing it is: an agreement between clients that are
/// running.
///
/// A claim names an object *and the incarnation of it*. A slot number is not an
/// identity - remove the file at slot twelve and the next `create` may be handed
/// slot twelve - so a claim recorded as "twelve" would come to hold a file
/// nobody claimed, and, worse, would lock its new owner out of it. The same
/// count that makes a capability name a thing makes a claim name one.
///
/// A value type with no reference to a disk, which is what makes the rule here
/// something that can be put under test rather than reasoned about: every case
/// that matters needs two holders, and two holders is not a thing one process
/// can arrange.
public struct FSLeases {

    /// How many claims at once. Small on purpose: a claim is for a change that
    /// takes several requests, and a client with more than a couple of those in
    /// flight is doing something this file system has not been asked for.
    public static let capacity = 8

    private var objects: InlineArray<8, UInt32?> = InlineArray(repeating: nil)
    private var ages   : InlineArray<8, UInt32>  = InlineArray(repeating: 0)
    private var holders: InlineArray<8, UInt32?> = InlineArray(repeating: nil)

    /// How many claims were refused because there was no room for them.
    ///
    /// A fixed table with no way to see it fill up is a fixed table whose size
    /// is a guess nobody can check. A refusal for want of room and a refusal
    /// because somebody else holds the object are the same answer to the client
    /// and completely different facts about the server, and without this the
    /// second is what a full table looks like.
    public private(set) var saturations: UInt32 = 0

    /// Whether every slot is taken. Read after a refused `claim` to tell "no
    /// room" from "not yours".
    public var isFull: Bool {
        for index in 0..<Self.capacity where objects[index] == nil { return false }
        return true
    }

    public init() {}


    /// What a slot holds, for a caller sweeping the table against a disk.
    public func entry(at index: Int) -> (object: UInt32, age: UInt32)? {
        guard index < Self.capacity, let object = objects[index] else { return nil }

        return (object, ages[index])
    }


    /// Lets go of whatever is in `index`.
    public mutating func forget(at index: Int) {
        guard index < Self.capacity else { return }

        objects[index] = nil
        holders[index] = nil
    }


    /// Claims `object`, at the incarnation it is now, for `holder`.
    ///
    /// `false` when somebody else holds it or there is no room to record another.
    /// Claiming twice is not an error: a client asking again for what it already
    /// holds gets yes, because that is what it is entitled to.
    public mutating func claim(
        _   object    : UInt32,
            generation: UInt32,
        for holder    : UInt32
    ) -> Bool {

        for index in 0..<Self.capacity where objects[index] == object {

            // A claim on what used to be in this slot is not a claim on what is
            // in it now. Forgotten here rather than tripped over later.
            guard ages[index] == generation else {
                forget(at: index)
                break
            }

            return holders[index] == holder
        }

        for index in 0..<Self.capacity where objects[index] == nil {
            objects[index] = object
            ages[index]    = generation
            holders[index] = holder

            return true
        }

        saturations &+= 1
        return false
    }


    /// Lets go of a claim, if `holder` is the one holding it.
    public mutating func release(
        _    object: UInt32,
        from holder: UInt32
    ) {
        for index in 0..<Self.capacity
        where objects[index] == object && holders[index] == holder {
            forget(at: index)
        }
    }


    /// Whether `holder` may change `object`, which is now at `generation`.
    ///
    /// `nil` for the generation says the object is not there at all, which makes
    /// any claim on that slot stale by definition.
    ///
    /// Unclaimed is allowed. A claim is something a client asks for, not
    /// something the file system imposes on everybody who never asked.
    public mutating func mayChange(
        _  object    : UInt32,
           generation: UInt32?,
        by holder    : UInt32
    ) -> Bool {

        for index in 0..<Self.capacity where objects[index] == object {

            guard let generation, ages[index] == generation else {
                forget(at: index)
                return true
            }

            return holders[index] == holder
        }

        return true
    }


    /// Lets go of everything `holder` was holding.
    ///
    /// What happens when a client attaches again, which is the only certain
    /// moment this table gets. A client that dies without coming back keeps its
    /// claims until the object underneath one of them moves on - knowing a
    /// client has died needs the kernel to say so, and it does not yet.
    public mutating func forget(everythingHeldBy holder: UInt32) {
        for index in 0..<Self.capacity where holders[index] == holder {
            forget(at: index)
        }
    }
}
