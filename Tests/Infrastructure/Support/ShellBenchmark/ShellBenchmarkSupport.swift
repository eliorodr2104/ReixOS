//
//  ShellBenchmarkSupport.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

import Foundation

public enum BenchmarkConfigurationError: Error, Equatable {
    case usage
}

public struct BenchmarkConfiguration: Equatable, Sendable {
    public var iterations: Int = 2_000
    public var batches: Int = 10
    public var warmup: Int = 200
    public var json = false
    public var raw  = false
    public init() {}
    public static let usage = "usage: ShellBench [--iterations N|--samples N] [--batches N>=10] [--warmup N] [--json|--format json] [--raw]"
    public static func parse(_ arguments: [String]) -> Result<BenchmarkConfiguration, BenchmarkConfigurationError> {
        var value = BenchmarkConfiguration()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
                case "--":
                    index += 1
                    continue
                case "--json": value.json = true
                case "--raw": value.raw = true
                case "--iterations", "--samples", "--batches", "--warmup":
                    guard index + 1 < arguments.count, let count = Int(arguments[index + 1]), count > 0 else { return .failure(.usage) }
                    if arguments[index] == "--iterations" || arguments[index] == "--samples" { value.iterations = count }
                    if arguments[index] == "--batches" { value.batches = count }
                    if arguments[index] == "--warmup" { value.warmup = count }
                    index += 1
                case "--format":
                    guard index + 1 < arguments.count else { return .failure(.usage) }
                    if arguments[index + 1] == "json" { value.json = true }
                    else if arguments[index + 1] != "text" { return .failure(.usage) }
                    index += 1
                default: return .failure(.usage)
            }
            index += 1
        }
        return value.batches >= 10 ? .success(value) : .failure(.usage)
    }
}

public enum BenchmarkStatus: String, Sendable { case measured, unsupported }
public struct BenchmarkStatistics: Equatable, Sendable {
    public let samples: [UInt64]
    public init(samples: [UInt64]) { self.samples = samples }
    private func rank(_ p: Double) -> UInt64 {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index  = Swift.max(0, Int(ceil(p * Double(sorted.count))) - 1)
        return sorted[index]
    }
    public var min: UInt64 { samples.min() ?? 0 }
    public var p50: UInt64 { rank(0.50) }
    public var p95: UInt64 { rank(0.95) }
    public var p99: UInt64 { rank(0.99) }
    public var max: UInt64 { samples.max() ?? 0 }
    public var mean: UInt64 {
        guard !samples.isEmpty else { return 0 }
        var total = 0.0
        for sample in samples { total += Double(sample) }
        return UInt64(total / Double(samples.count))
    }
}
public struct BenchmarkResult: Sendable {
    public let name: String; public let status: BenchmarkStatus; public let workload: String; public let checksum: Int; public let statistics: BenchmarkStatistics?; public let requestedSize: Int?; public let supportedLimit: Int?; public let reason: String?
    public static func unsupported(_ name: String, requested: Int, limit: Int, reason: String) -> BenchmarkResult { .init(name: name, status: .unsupported, workload: name, checksum: 0, statistics: nil, requestedSize: requested, supportedLimit: limit, reason: reason) }
}
public enum ShellBenchmark {
    /// The arithmetic seam behind a batch: tests can supply deterministic
    /// clock readings without depending on host scheduler noise.
    public static func adjustedPerOperation(
        elapsed   : UInt64,
        control   : UInt64,
        iterations: Int
    ) -> UInt64 {
        precondition(iterations > 0)
        guard elapsed >= control else { return 0 }
        return (elapsed - control) / UInt64(iterations)
    }

    public static func measure(
        name         : String,
        workload     : String,
        configuration: BenchmarkConfiguration,
        body         : () -> Int
    ) -> BenchmarkResult {
        var checksum = 0
        for _ in 0..<configuration.warmup { checksum &+= body() }
        var samples: [UInt64] = []; samples.reserveCapacity(configuration.batches)
        for _ in 0..<configuration.batches {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<configuration.iterations { checksum &+= body() }
            let elapsed           = DispatchTime.now().uptimeNanoseconds - start
            let controlStart      = DispatchTime.now().uptimeNanoseconds
            var controlDependency = checksum
            for index in 0..<configuration.iterations {
                controlDependency = controlChecksum(seed: controlDependency ^ index)
            }
            let control = DispatchTime.now().uptimeNanoseconds - controlStart
            checksum &+= controlDependency
            samples.append(adjustedPerOperation(elapsed: elapsed, control: control, iterations: configuration.iterations))
        }
        return .init(name: name, status: .measured, workload: workload, checksum: checksum, statistics: .init(samples: samples), requestedSize: nil, supportedLimit: nil, reason: nil)
    }
    @inline(never) public static func controlChecksum(seed: Int) -> Int {
        (seed &* 1_103_515_245) &+ 12_345
    }
    public static func json(
        _ results    : [BenchmarkResult],
        configuration: BenchmarkConfiguration,
        environment  : [String: String]
    ) -> Result<String, Error> {
        var object: [[String: Any]] = []
        for result in results { var item: [String: Any] = ["name": result.name, "status": result.status.rawValue, "workload": result.workload]; if let s = result.statistics { item["unit"] = "ns-per-operation"; item["min"] = s.min; item["p50"] = s.p50; item["p95"] = s.p95; item["p99"] = s.p99; item["max"] = s.max; item["mean"] = s.mean; item["checksum"] = result.checksum; if configuration.raw { item["raw_batch_samples"] = s.samples } } else { item["requested_size"] = result.requestedSize!; item["supported_limit"] = result.supportedLimit!; item["reason"] = result.reason! }; object.append(item) }
        let root: [String: Any] = ["schema_version": 2, "provenance": "host_microbenchmark", "host_arch": environment["HOST_ARCH"] ?? "unavailable", "os_version": ProcessInfo.processInfo.operatingSystemVersionString, "build": environment["BENCH_BUILD"] ?? "unavailable", "git_revision": environment["GIT_REVISION"] ?? "unavailable", "dirty_state": environment["GIT_DIRTY"] ?? "unavailable", "iterations": configuration.iterations, "batches": configuration.batches, "warmup": configuration.warmup, "results": object]
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            return .success(String(decoding: data, as: UTF8.self))
        } catch { return .failure(error) }
    }
}
