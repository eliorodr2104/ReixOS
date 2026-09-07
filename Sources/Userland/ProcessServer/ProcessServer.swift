//
//  ProcessServer.swift
//  ReixOS
//

import Reix
import ReixABI
import ProcessServerCore

public struct ProcessServer: Service {
    public static let manifest = ServiceManifest(provides: .parent)

    private static let supervisedCapacity = 8
    private static let bootstrapPatience  : UInt32 = 200
    private static let copyChunk          = 4096

    private struct SupervisedJob {
        let handle: UInt32
        let pid   : PID
    }

    private struct LaunchBinding {
        let name  : EnvironmentBinding
        let handle: UInt32
        let rights: CapRights
    }

    public let serviceEndpoint : UInt32
    private let environment    : Environment
    private let files          : FileSystemClient?
    private var jobs           = InlineArray<8, SupervisedJob?>(repeating: nil)
    private var nextNonce      : UInt32 = 1

    public init(
        environment: Environment,
        endpoint   : UInt32
    ) {
        self.environment = environment
        self.serviceEndpoint = endpoint
        self.files = environment.programs.flatMap(FileSystemClient.init(fileSystem:))
    }

    public mutating func run() {
        print("[ PSRV  ] ProcessServer running")

        while true {
            if var request = receive(
                handle : serviceEndpoint,
                timeout: 10
            ) {
                if let operation = ProcessServerOperation(
                    rawValue: request.message.tag.label
                ) {
                    handle(operation, request: &request)
                } else {
                    _ = reply(message: ProcessServerStatus.badRequest.response)
                }

                if let stray = request.takeGrant() { _ = capDrop(stray) }
            }

            sweepJobs()
        }
    }

    public mutating func handle(
        _ operation: ProcessServerOperation,
        request    : inout ReceivedMessage
    ) {
        switch operation {
            case .launch:
                launch(request: &request)
        }
    }

    private mutating func launch(request: inout ReceivedMessage) {
        guard request.grantedCap == nil,
              let requested = ProcessLaunchRequest.name(from: request.message),
              let profile   = ProgramProfile.identify(
                requested.bytes,
                length: requested.length
              )
        else {
            _ = reply(message: ProcessServerStatus.badRequest.response)
            return
        }

        guard firstFreeJobSlot() != nil else {
            _ = reply(message: ProcessServerStatus.capacity.response)
            return
        }

        guard let files else {
            _ = reply(message: ProcessServerStatus.unavailable.response)
            return
        }

        var name   = requested.bytes
        let opened = withUnsafeBytes(of: &name) { raw in
            files.open(
                raw.baseAddress!,
                length: requested.length
            )
        }

        guard opened.status == .ok,
              let file = opened.file,
              file.kind == .file
        else {
            _ = reply(message: ProcessServerStatus.notFound.response)
            return
        }

        var source = FileELFSource(
            files : files,
            object: file.object,
            size  : file.size
        )

        guard case .success(let plan) = ELFPlanner.plan(from: &source) else {
            _ = reply(message: ProcessServerStatus.malformedELF.response)
            return
        }

        guard let bindings = launchBindings(for: profile) else {
            _ = reply(message: ProcessServerStatus.unavailable.response)
            return
        }

        let created = taskCreate()
        guard created.succeeded else {
            _ = reply(message: ProcessServerStatus.taskFailure.response)
            return
        }

        let task      = created.task
        let bootstrap = created.bootstrap

        guard build(task: task, from: file, plan: plan, files: files) else {
            discardTask(task, bootstrap: bootstrap)
            _ = reply(message: ProcessServerStatus.taskFailure.response)
            return
        }

        let started = taskStart(task)
        guard started.result == .ok else {
            discardTask(task, bootstrap: bootstrap)
            _ = reply(message: ProcessServerStatus.taskFailure.response)
            return
        }

        let nonce = takeNonce()
        guard bootstrapChild(
            job     : task,
            endpoint: bootstrap,
            nonce   : nonce,
            bindings: bindings
        ) else {
            discardJob(task, pid: started.pid, bootstrap: bootstrap)
            _ = reply(message: ProcessServerStatus.bootstrapFailure.response)
            return
        }

        _ = capDrop(bootstrap)

        guard let slot = firstFreeJobSlot() else {
            discardJob(task, pid: started.pid, bootstrap: nil)
            _ = reply(message: ProcessServerStatus.capacity.response)
            return
        }

        jobs[slot] = SupervisedJob(handle: task, pid: started.pid)

        let delivered = reply(
            message    : ProcessServerStatus.ok.response,
            grant      : task,
            grantRights: [.taskTerminate, .taskStatus]
        )

        guard delivered == .ok else {
            jobs[slot] = nil
            discardJob(task, pid: started.pid, bootstrap: nil)
            return
        }
    }

    private func build(
        task     : UInt32,
        from file: FSFile,
        plan     : ELFLoadPlan,
        files    : FileSystemClient
    ) -> Bool {
        for index in 0..<plan.regionCount {
            guard let region = plan.region(at: index),
                  taskMapAnonymous(
                    task,
                    at   : region.address,
                    pages: region.pages
                  ) == .ok
            else { return false }
        }

        let stackBase = TaskABI.stackTop - TaskABI.pageSize
        guard taskMapAnonymous(task, at: stackBase, pages: 1) == .ok else {
            return false
        }

        let copied = withUnsafeTemporaryAllocation(
            of      : UInt8.self,
            capacity: Self.copyChunk
        ) { buffer -> Bool in
            for index in 0..<plan.copyCount {
                guard let copy = plan.copy(at: index) else { return false }

                var offset: UInt64 = 0
                while offset < copy.byteCount {
                    let remaining = copy.byteCount - offset
                    let wanted    = remaining < UInt64(buffer.count)
                        ? remaining
                        : UInt64(buffer.count)

                    let read = files.read(
                        file.object,
                        at   : copy.fileOffset + offset,
                        into : UnsafeMutableRawPointer(buffer.baseAddress!),
                        count: wanted
                    )
                    guard read.status == .ok, read.bytes == wanted else {
                        return false
                    }

                    guard taskWrite(
                        task,
                        at   : copy.virtualAddress + offset,
                        bytes: UnsafeRawPointer(buffer.baseAddress!),
                        count: Int(wanted)
                    ) == .ok else { return false }

                    offset += wanted
                }
            }
            return true
        }
        guard copied else { return false }

        for index in 0..<plan.regionCount {
            guard let region = plan.region(at: index),
                  taskSealAndProtect(
                    task,
                    at         : region.address,
                    pages      : region.pages,
                    permissions: region.permissions
                  ) == .ok
            else { return false }
        }

        guard taskSealAndProtect(
            task,
            at         : stackBase,
            pages      : 1,
            permissions: [.read, .write]
        ) == .ok else { return false }

        return taskSetContext(
            task,
            entry       : plan.entry,
            stack       : TaskABI.stackTop,
            programBreak: plan.programBreak
        ) == .ok
    }

    private func launchBindings(
        for profile: ProgramProfile
    ) -> (storage: InlineArray<16, LaunchBinding?>, count: Int)? {
        var result = InlineArray<16, LaunchBinding?>(repeating: nil)
        var count  = 0

        let required = profile.bindings
        for index in 0..<required.count {
            guard let spec = required.storage[index] else { return nil }
            guard let handle = handle(for: spec.binding) else {
                print("[ PSRV  ] missing required environment binding ", terminator: "")
                print(spec.binding.rawValue)
                return nil
            }

            result[count] = LaunchBinding(
                name  : spec.binding,
                handle: handle,
                rights: spec.rights
            )
            count += 1
        }

        return (result, count)
    }

    private func handle(for binding: EnvironmentBinding) -> UInt32? {
        switch binding {
            case .console: return environment.console
            case .nameServer: return environment.nameServer
            case .profiler: return environment.profiler
            // Console and terminal are one TextSurface authority at bootstrap;
            // the fallback saves two of the ten legacy grant slots.
            case .terminal: return environment.terminal ?? environment.console
            case .container: return environment.container
            case .shared: return environment.shared
            case .block: return environment.block
            case .profileMarker: return environment.profileMarker
            case .inputSource: return environment.inputSource
            case .inputConsumer: return environment.inputConsumer
            case .inputFocus: return environment.inputFocus
            case .serialReader: return environment.serialReader
            case .serialWriter: return environment.serialWriter
            case .programs: return environment.programs
            case .processServer: return serviceEndpoint
            case .sessionControl: return environment.sessionControl
        }
    }

    private func bootstrapChild(
        job     : UInt32,
        endpoint: UInt32,
        nonce   : UInt32,
        bindings: (storage: InlineArray<16, LaunchBinding?>, count: Int)
    ) -> Bool {
        guard deliver(
            EnvironmentTransaction.begin(
                count: UInt32(bindings.count),
                nonce: nonce
            ),
            to: endpoint,
            job: job
        ), acknowledge(
            endpoint,
            index: UInt32.max,
            nonce: nonce
        ) else { return false }

        for index in 0..<bindings.count {
            guard let binding = bindings.storage[index],
                  deliver(
                    EnvironmentTransaction.binding(
                        binding.name,
                        index: UInt32(index),
                        nonce: nonce
                    ),
                    to: endpoint,
                    job: job,
                    grant: binding.handle,
                    rights: binding.rights
                  ),
                  acknowledge(
                    endpoint,
                    index: UInt32(index),
                    nonce: nonce
                  )
            else { return false }
        }

        guard deliver(
            EnvironmentTransaction.commit(nonce: nonce),
            to: endpoint,
            job: job
        ), let ready = receive(
            handle : endpoint,
            timeout: Self.bootstrapPatience
        ) else { return false }

        return ready.message.tag.label == EnvironmentTransactionOperation.ready.rawValue &&
            ready.message.tag.length == 1 &&
            ready.message.words[0] == nonce &&
            ready.grantedCap == nil
    }

    private func deliver(
        _ message  : Message,
        to endpoint: UInt32,
        job        : UInt32,
        grant      : UInt32? = nil,
        rights     : CapRights = []
    ) -> Bool {
        for _ in 0..<Self.bootstrapPatience {
            let outcome = trySend(
                handle     : endpoint,
                message    : message,
                grant      : grant,
                grantRights: rights
            )

            if outcome.isDelivered { return outcome == .ok }
            guard outcome == .wouldBlock,
                  jobStatus(job).state == .running
            else { return false }

            _ = sleep(for: .milliseconds(10))
        }

        return false
    }

    private func acknowledge(
        _ endpoint: UInt32,
        index     : UInt32,
        nonce     : UInt32
    ) -> Bool {
        guard let answer = receive(
            handle : endpoint,
            timeout: Self.bootstrapPatience
        ) else { return false }

        return answer.message.tag.label == EnvironmentTransactionOperation.acknowledgement.rawValue &&
            answer.message.tag.length == 2 &&
            answer.message.words[0] == index &&
            answer.message.words[1] == nonce &&
            answer.grantedCap == nil
    }

    private mutating func sweepJobs() {
        for index in 0..<jobs.count {
            guard let job = jobs[index] else { continue }

            switch jobStatus(job.handle).state {
                case .exited:
                    _ = reapChild(for: job.pid)
                    _ = capDrop(job.handle)
                    jobs[index] = nil

                case .aborted, .invalid:
                    _ = capDrop(job.handle)
                    jobs[index] = nil

                case .configuring, .running:
                    break
            }
        }
    }

    private func firstFreeJobSlot() -> Int? {
        for index in 0..<jobs.count where jobs[index] == nil { return index }
        return nil
    }

    private mutating func takeNonce() -> UInt32 {
        let value = nextNonce == 0 ? 1 : nextNonce
        nextNonce = value &+ 1
        return value
    }

    private func discardTask(
        _ task   : UInt32,
        bootstrap: UInt32
    ) {
        _ = taskAbort(task)
        _ = capDrop(task)
        _ = capDrop(bootstrap)
    }

    private func discardJob(
        _ job    : UInt32,
        pid      : PID,
        bootstrap: UInt32?
    ) {
        _ = jobCancel(job)
        _ = reapChild(for: pid)
        _ = capDrop(job)
        if let bootstrap { _ = capDrop(bootstrap) }
    }

}

private struct FileELFSource: ELFByteSource {
    let files : FileSystemClient
    let object: UInt32
    let size  : UInt64

    mutating func read(
        at offset       : UInt64,
        into destination: UnsafeMutableRawPointer,
        count           : Int
    ) -> Bool {
        guard count > 0 else { return false }
        let result = files.read(
            object,
            at   : offset,
            into : destination,
            count: UInt64(count)
        )
        return result.status == .ok && result.bytes == UInt64(count)
    }
}
