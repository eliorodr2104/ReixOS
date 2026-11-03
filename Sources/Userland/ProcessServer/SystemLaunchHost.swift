//
//  SystemLaunchHost.swift
//  ReixOS
//

import Reix
import ReixABI
import ProcessServerCore

/// Gives the launch policy system effects without making it depend on syscalls.
struct SystemLaunchHost: LaunchHost {
    typealias File = FileELFSource

    let environment    : Environment
    let files          : FileSystemClient?
    let serviceEndpoint: UInt32
    #if REIX_BOOT_DIAGNOSTIC
    var diesOnCreate = false
    #endif

    func handle(for binding: EnvironmentBinding) -> UInt32? {
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

    mutating func openProgram(
        _ name: InlineArray<12, UInt8>, length: Int
    ) throws(ProcessServerStatus) -> FileELFSource {
        guard let files else { throw .unavailable }
        var bytes = name
        let opened = withUnsafeBytes(of: &bytes) { files.open($0.baseAddress!, length: length) }
        guard opened.status == .ok, let file = opened.file, file.kind == .file else { throw .notFound }
        return FileELFSource(files: files, object: file.object)
    }

    mutating func createTask(
        _ name: InlineArray<12, UInt8>, length: Int
    ) -> (task: UInt32, bootstrap: UInt32)? {
        #if REIX_BOOT_DIAGNOSTIC
        if diesOnCreate {
            print("[ PSRV  ] the loader exits with its claim held")
            exit(code: 7)
        }
        #endif
        var bytes = name
        let created = withUnsafeBytes(of: &bytes) {
            taskCreate(name: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), length: length)
        }
        return created.succeeded ? (created.task, created.bootstrap) : nil
    }

    mutating func map(_ task: UInt32, at address: UInt64, pages: UInt32) -> Bool {
        taskMapAnonymous(task, at: address, pages: pages) == .ok
    }

    mutating func write(_ task: UInt32, at address: UInt64, bytes: UnsafeRawPointer, count: Int) -> Bool {
        taskWrite(task, at: address, bytes: bytes, count: count) == .ok
    }

    mutating func seal(_ task: UInt32, at address: UInt64, pages: UInt32, permissions: TaskMemoryPermissions) -> Bool {
        taskSealAndProtect(task, at: address, pages: pages, permissions: permissions) == .ok
    }

    mutating func setContext(_ task: UInt32, entry: UInt64, stack: UInt64, programBreak: UInt64) -> Bool {
        taskSetContext(task, entry: entry, stack: stack, programBreak: programBreak) == .ok
    }

    mutating func start(_ task: UInt32) -> UInt64? {
        let started = taskStart(task)
        return started.result == .ok ? started.pid : nil
    }

    mutating func abort(_ task: UInt32) { _ = taskAbort(task) }
    mutating func cancel(_ job: UInt32) { _ = jobCancel(job) }
    func state(of job: UInt32) -> TaskState { jobStatus(job).state }
    mutating func reap(_ pid: UInt64) { _ = reapChild(for: pid) }
    mutating func drop(_ handle: UInt32) { _ = capDrop(handle) }

    mutating func trySend(_ endpoint: UInt32, _ message: Message, grant: UInt32?, rights: CapRights) -> IPCStatus {
        Reix.trySend(handle: endpoint, message: message, grant: grant, grantRights: rights)
    }

    mutating func tryReceive(_ endpoint: UInt32) -> (message: Message, grant: UInt32?)? {
        guard var received = Reix.tryReceive(handle: endpoint), received.arrived else { return nil }
        return (received.message, received.takeGrant())
    }

    func alive(_ identity: UInt32) -> Bool { identityAlive(identity) }

    mutating func reply(_ status: ProcessServerStatus, to identity: UInt32, job: UInt32?) -> Bool {
        Reix.reply(message: status.response, grant: job, grantRights: [.taskTerminate, .taskStatus], to: identity) == .ok
    }

    mutating func reclaimed(_ cause: LaunchReclaim) {
        #if REIX_BOOT_DIAGNOSTIC
        switch cause {
            case .deadline: print("[ PSRV  ] a launch past its deadline was reclaimed")
            case .requesterGone: print("[ PSRV  ] a launch whose requester died was reclaimed")
            case .programDied: print("[ PSRV  ] a launch whose program died was reclaimed")
        }
        #endif
    }
}

/// The program file through ProcessServer's view of the program folder, which
/// holds `FSRights.loader`: it may read a program and claim it, never write it.
struct FileELFSource: ProgramFile {
    let files : FileSystemClient
    let object: UInt32
    private(set) var size: UInt64 = 0

    mutating func claim() -> ProcessServerStatus {
        let claimed = ProcessServerStatus(claiming: files.lock(object))
        guard claimed == .ok else { return claimed }

        // Asked again under the claim: the size `open` saw is from before it.
        guard let info = files.info(of: object) else {
            files.unlock(object)
            return .unavailable
        }

        size = info.size
        return .ok
    }

    mutating func release() {
        files.unlock(object)
    }

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
