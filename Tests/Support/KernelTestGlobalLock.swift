//
//  KernelTestGlobalLock.swift
//  ReixOS
//
//  Host kernel fixtures temporarily replace process-wide kernel state. Swift
//  Testing may run different suites in one test bundle at the same time, so a
//  suite-local `.serialized` trait cannot protect those replacements.

import Darwin

private final class KernelTestRecursiveLock: @unchecked Sendable {
    private var mutex = pthread_mutex_t()

    init() {
        var attributes = pthread_mutexattr_t()
        precondition(pthread_mutexattr_init(&attributes) == 0)
        defer { pthread_mutexattr_destroy(&attributes) }
        precondition(pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE) == 0)
        precondition(pthread_mutex_init(&mutex, &attributes) == 0)
    }

    deinit { pthread_mutex_destroy(&mutex) }

    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        precondition(pthread_mutex_lock(&mutex) == 0)
        defer { precondition(pthread_mutex_unlock(&mutex) == 0) }
        return try body()
    }
}

private let kernelTestGlobalLock = KernelTestRecursiveLock()

/// Serializes host fixtures that temporarily install process-wide kernel state.
/// Recursive locking is intentional because high-level fixtures compose the
/// smaller current-process and archive fixtures.
public func withKernelTestGlobals<Result>(
    _ body: () throws -> Result
) rethrows -> Result {
    try kernelTestGlobalLock.withLock(body)
}
