#!/usr/bin/env python3
"""Measure the T05 Swift adapter over the same host BucketsHeap lifecycle.

The source checkout is snapshotted into an external directory. Raw interleaved
A/B/B/A samples and the full test log are retained; host nanoseconds are not a
latency claim for the AArch64 target.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


MARKER = "RUNTIME_BENCHMARK_JSON "


def resolve_tool(environment: str, fallback: str) -> str:
    requested = os.environ.get(environment, fallback)
    resolved = shutil.which(requested)
    if resolved is None:
        raise RuntimeError(f"{requested!r} was not found; set {environment}")
    return resolved


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def snapshot(source: Path, target: Path, git: str) -> dict[str, str]:
    names = subprocess.check_output(
        [git, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=source,
    ).decode().split("\0")
    manifest: dict[str, str] = {}
    for name in names:
        if not name:
            continue
        source_file = source / name
        if not source_file.is_file():
            continue
        target_file = target / name
        target_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_file, target_file, follow_symlinks=False)
        manifest[name] = sha256(target_file)
    return manifest


def median(values: list[int]) -> float:
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return float(ordered[middle])
    return (ordered[middle - 1] + ordered[middle]) / 2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    parser.add_argument("--iterations", type=int, default=20000)
    parser.add_argument("--samples", type=int, default=20)
    arguments = parser.parse_args()
    if arguments.iterations <= 0 or arguments.samples < 4 or arguments.samples % 4:
        raise RuntimeError("iterations must be positive and samples a multiple of four")

    source = Path(__file__).resolve().parent.parent
    evidence = (
        arguments.output.resolve()
        if arguments.output
        else Path(tempfile.mkdtemp(prefix="reix-runtime-benchmark-"))
    )
    if arguments.output:
        if evidence.exists() and any(evidence.iterdir()):
            raise RuntimeError(f"output directory is not empty: {evidence}")
        evidence.mkdir(parents=True, exist_ok=True)

    workspace = evidence / "workspace"
    workspace.mkdir()
    swift = resolve_tool("REIX_SWIFT", "swift")
    git = resolve_tool("REIX_GIT", "git")
    manifest = snapshot(source, workspace, git)
    (evidence / "initial-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )

    benchmark_source = workspace / "Tests/Benchmarks/KernelRuntimeBenchmark.swift"
    injected = workspace / "Tests/KernelUnitTests/T05RuntimeBenchmark.swift"
    shutil.copy2(benchmark_source, injected)

    command = [
        swift, "test", "--disable-sandbox", "--scratch-path", "build-host",
        "-c", "release", "--no-parallel", "--filter", "KernelRuntimeBenchmark",
    ]
    environment = {
        **os.environ,
        "CLANG_MODULE_CACHE_PATH": str(evidence / "module-cache-clang"),
        "SWIFTPM_MODULECACHE_OVERRIDE": str(evidence / "module-cache-swift"),
        "REIX_RUNTIME_BENCH_ITERATIONS": str(arguments.iterations),
        "REIX_RUNTIME_BENCH_SAMPLES": str(arguments.samples),
    }
    log = evidence / "benchmark.log"
    with log.open("wb") as output:
        result = subprocess.run(
            command,
            cwd=workspace,
            env=environment,
            stdout=output,
            stderr=subprocess.STDOUT,
        )
    text = log.read_text(errors="replace")
    matches = re.findall(r"^" + re.escape(MARKER) + r"(.+)$", text, re.MULTILINE)
    if result.returncode != 0 or len(matches) != 1:
        raise RuntimeError(f"benchmark failed or emitted no unique marker; see {log}")

    raw = json.loads(matches[0])
    iterations = int(raw["iterations"])
    rows = []
    for raw_row in raw["rows"]:
        adapter = [int(value) for value in raw_row["adapter_ns"]]
        direct = [int(value) for value in raw_row["direct_ns"]]
        rows.append({
            "bytes": int(raw_row["bytes"]),
            "adapterNanoseconds": adapter,
            "directNanoseconds": direct,
            "adapterMedianNanosecondsPerLifecycle": median(adapter) / iterations,
            "directMedianNanosecondsPerLifecycle": median(direct) / iterations,
            "adapterMinusDirectMedianNanoseconds": (
                median(adapter) - median(direct)
            ) / iterations,
        })
    summary = {
        "scope": (
            "host process, release build, balanced slab and large allocate/free "
            "churn through the runtime adapter and BucketsHeap directly"
        ),
        "targetClaim": False,
        "command": command,
        "source": str(benchmark_source),
        "sourceSHA256": sha256(benchmark_source),
        "raw": raw,
        "rows": rows,
        "balanced": raw["pages_before"] == raw["pages_after"],
        "log": str(log),
    }
    (evidence / "result.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    print(f"evidence: {evidence}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"kernel-runtime-benchmark: {error}", file=sys.stderr)
        raise SystemExit(2)
