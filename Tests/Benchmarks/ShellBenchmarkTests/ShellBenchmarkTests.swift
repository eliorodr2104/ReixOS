//
//  ShellBenchmarkTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

import Testing
import Foundation
import ShellBenchmarkSupport

struct ShellBenchmarkTests {
    @Test func nearestRankAndJSONAreStable() throws {
        let statistics = BenchmarkStatistics(samples: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        #expect(statistics.p50 == 5 && statistics.p95 == 10 && statistics.p99 == 10)
        var configuration = BenchmarkConfiguration(); configuration.iterations = 1; configuration.warmup = 1
        let result        = ShellBenchmark.measure(name: "x", workload: "x", configuration: configuration) { 1 }
        let json          = try ShellBenchmark.json([result, .unsupported("too-big", requested: 256, limit: 250, reason: "capacity")], configuration: configuration, environment: [:]).get()
        #expect(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] != nil)
    }
    @Test func invalidConfigurationFailsClosed() {
        guard case .failure = BenchmarkConfiguration.parse(["--batches", "9"]) else { Issue.record("invalid configuration was accepted"); return }
    }

    @Test func overheadSaturatesWithoutUnderflow() {
        #expect(ShellBenchmark.adjustedPerOperation(elapsed: 7, control: 9, iterations: 1) == 0)
    }

    @Test func antiTautologyDistinguishesSubtractedControl() {
        let corrected = ShellBenchmark.adjustedPerOperation(elapsed: 150, control: 50, iterations: 10)
        let mutated   = 150 / UInt64(10)
        #expect(corrected == 10)
        #expect(corrected != mutated)
    }

    @Test func batchesAndChecksumsAreDeterministic() {
        var configuration = BenchmarkConfiguration()
        configuration.iterations = 1
        configuration.batches = 10
        configuration.warmup = 1
        let first  = ShellBenchmark.measure(name: "same", workload: "same", configuration: configuration) { 7 }
        let second = ShellBenchmark.measure(name: "same", workload: "same", configuration: configuration) { 7 }
        #expect(first.statistics?.samples.count == configuration.batches)
        #expect(first.checksum == second.checksum)
    }

    @Test func controlSeamIsDeterministicAndRetainsSubtractedControl() {
        #expect(ShellBenchmark.controlChecksum(seed: 7) == ShellBenchmark.controlChecksum(seed: 7))
        #expect(ShellBenchmark.controlChecksum(seed: 7) != ShellBenchmark.controlChecksum(seed: 8))
        #expect(ShellBenchmark.adjustedPerOperation(elapsed: 100, control: 40, iterations: 10) == 6)
    }

    @Test func jsonEscapesAndSeparatesUnsupportedMetrics() throws {
        var configuration = BenchmarkConfiguration()
        configuration.iterations = 1
        configuration.warmup = 1
        configuration.raw = true
        let measured    = ShellBenchmark.measure(name: "name\\\"\n", workload: "work\\\"\n", configuration: configuration) { 1 }
        let unsupported = BenchmarkResult.unsupported("bad\\\"\n", requested: 256, limit: 1, reason: "why\\\"\n")
        let text        = try ShellBenchmark.json([measured, unsupported], configuration: configuration, environment: [:]).get()
        let root        = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        for key in ["schema_version", "provenance", "host_arch", "os_version", "build", "git_revision", "dirty_state", "iterations", "batches", "warmup", "results"] { #expect(root[key] != nil) }
        let values = try #require(root["results"] as? [[String: Any]])
        #expect(values[0]["name"] as? String == "name\\\"\n")
        #expect(values[0]["p50"] != nil && values[0]["checksum"] != nil)
        #expect(values[1]["reason"] as? String == "why\\\"\n")
        for key in ["checksum", "min", "p50", "p95", "p99", "max", "mean", "raw_batch_samples", "throughput_per_second"] { #expect(values[1][key] == nil) }
    }

    @Test func cliAcceptsValidAndRejectsInvalidOptions() {
        guard case .success = BenchmarkConfiguration.parse(["--iterations", "1", "--batches", "10", "--warmup", "1", "--json", "--raw"]) else { Issue.record("valid CLI refused"); return }
        for arguments in [["--wat"], ["--iterations"], ["--warmup", "0"], ["--batches", "9"]] { guard case .failure = BenchmarkConfiguration.parse(arguments) else { Issue.record("invalid CLI accepted") ; return } }
    }
}
