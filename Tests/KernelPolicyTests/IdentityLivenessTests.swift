//
//  IdentityLivenessTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.


import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// The question every userland server needed and could not ask: is the principal
/// this table slot is keyed on still there?
///
/// What is worth testing is not the loop but the three answers that are easy to
/// get wrong, and each of which is a leak or a lie in the server above: a zombie
/// read as alive, a process the walk never reaches read as dead, and a badge
/// nobody was ever given read as alive.
///
/// `.serialized`, and the run needs `--no-parallel`: `PPMBackend.physicalOffset`
/// and `ProcessStatsIndex` are global and every spawn writes the second.
@Suite("Identity liveness", .serialized)
struct IdentityLivenessTests {

    /// A chain of `count` spawned processes, `initProcess` set to its head.
    ///
    /// A chain and not a fan, because the interesting failure is a walk that
    /// stops early: linked as siblings, a head-only check would still find
    /// everybody by accident.
    private func withChain(
        _ count: Int,
        _ body : (UnsafeMutablePointer<ProcessManager>, [UnsafeMutablePointer<Process>]) -> Void
    ) {
        withProcessManager(pages: 160) { _, _, manager in

            var chain: [UnsafeMutablePointer<Process>] = []

            for _ in 0..<count {
                guard let process = try? manager.pointee.spawnProcess() else {
                    Issue.record("could not spawn a process for the chain")
                    return
                }

                if let parent = chain.last {
                    parent.pointee.family.pushChild(process)
                    process.pointee.family.parent = parent
                }

                chain.append(process)
            }

            manager.pointee.initProcess = chain.first
            defer { manager.pointee.initProcess = nil }

            body(manager, chain)
        }
    }


    @Test("every process in the tree answers alive under its own identity")
    func aliveWhereverParked() {
        withChain(6) { manager, chain in
            for process in chain {
                #expect(manager.pointee.isAlive(identity: process.pointee.identity))
            }

            // The far end of the chain is the one that says the walk is a walk.
            // A check that only looked at the root would pass everything above.
            #expect(manager.pointee.isAlive(identity: chain.last!.pointee.identity))
        }
    }


    @Test("a terminated process is not alive, though it is still in the tree")
    func zombieIsDead() {
        withChain(4) { manager, chain in
            let corpse = chain[2]

            corpse.pointee.status = .terminated

            #expect(!manager.pointee.isAlive(identity: corpse.pointee.identity))

            // Its neighbours are untouched: a status is read per process and not
            // taken as the answer for the walk.
            #expect(manager.pointee.isAlive(identity: chain[1].pointee.identity))
            #expect(manager.pointee.isAlive(identity: chain[3].pointee.identity))
        }
    }


    @Test("a badge nobody was given is not alive")
    func strangerIsDead() {
        withChain(3) { manager, chain in
            let highest = chain.map(\.pointee.identity).max()!

            #expect(!manager.pointee.isAlive(identity: highest &+ 1))
            #expect(!manager.pointee.isAlive(identity: 0xDEAD_BEEF))
        }
    }


    @Test("zero is never alive, even with a process carrying it")
    func noPrincipalIsDead() {
        withChain(2) { manager, chain in

            // The guard has to be reached deliberately: with nothing wearing
            // zero the walk finds nothing and the answer is right by accident.
            let nameless = makeProcess(pid: 0)
            defer { destroyProcess(nameless) }

            #expect(nameless.pointee.identity == 0)

            chain[0].pointee.family.pushChild(nameless)
            nameless.pointee.family.parent = chain[0]

            #expect(!manager.pointee.isAlive(identity: 0))
            #expect(manager.pointee.isAlive(identity: chain[1].pointee.identity))
        }
    }


    @Test("a reaped corpse is out of the tree and therefore dead")
    func reapedIsDead() {
        withProcessManager(pages: 160) { ram, heap, manager in

            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            defer { UnsafeMutableRawPointer(scheduler).deallocate() }

            let ipc = UnsafeMutablePointer<KernelIPC>.allocate(capacity: 1)
            ipc.initialize(to: KernelIPC(ppm: ram.ppm, scheduler: scheduler, heap: heap))
            defer { ipc.deinitialize(count: 1); ipc.deallocate() }

            guard let parent = try? manager.pointee.spawnProcess(),
                  let child  = try? manager.pointee.spawnProcess()
            else {
                Issue.record("could not spawn the pair")
                return
            }

            parent.pointee.family.pushChild(child)
            child.pointee.family.parent = parent

            manager.pointee.initProcess = parent
            defer { manager.pointee.initProcess = nil }

            let identity = child.pointee.identity
            #expect(manager.pointee.isAlive(identity: identity))

            let context = SyscallContext(
                processManager: manager,
                scheduler     : scheduler,
                ipc           : ipc,
                ppm           : ram.ppm
            )

            // The whole death path, not a poked status: this is the route a
            // client's identity really leaves the world by.
            _ = manager.pointee.killProcess(child, reason: .exited(0), context: context)

            #expect(!manager.pointee.isAlive(identity: identity))
            #expect(manager.pointee.isAlive(identity: parent.pointee.identity))
        }
    }


    @Test("the syscall hands back one and zero, in x0")
    func syscallAnswers() {
        withChain(3) { manager, chain in

            // Everything but the process manager is a dangling one, which is the
            // claim: this syscall reads the process tree and touches nothing else.
            let context = SyscallContext(
                processManager: manager,
                scheduler     : UnsafeMutablePointer<KernelScheduler>(bitPattern: 1)!,
                ipc           : UnsafeMutablePointer<KernelIPC>(bitPattern: 1)!,
                ppm           : UnsafeMutablePointer<KernelPPM>(bitPattern: 1)!
            )

            var frame = Arch.TrapFrame()
            frame.x0 = UInt64(chain[2].pointee.identity)
            IdentityAliveSyscall.handle(frame: &frame, context: context)
            #expect(frame.x0 == 1)

            chain[2].pointee.status = .terminated
            frame.x0 = UInt64(chain[2].pointee.identity)
            IdentityAliveSyscall.handle(frame: &frame, context: context)
            #expect(frame.x0 == 0)
        }
    }
}
