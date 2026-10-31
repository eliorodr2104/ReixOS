#!/usr/bin/env python3
"""Run the release-only buddy allocator probe in an external snapshot."""

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


MARKER = "BUDDY_BENCHMARK_JSON "


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def nearest_rank(values: list[int], fraction: float) -> int:
    ordered = sorted(values)
    rank = max(1, int(len(ordered) * fraction + 0.999999999))
    return ordered[rank - 1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    parser.add_argument("--samples", type=int, default=10)
    args = parser.parse_args()
    if args.samples < 4:
        raise RuntimeError("samples must be at least four")

    source = Path(__file__).resolve().parent.parent
    evidence = args.output.resolve() if args.output else Path(
        tempfile.mkdtemp(prefix="reix-buddy-")
    )
    if args.output:
        if evidence.exists() and any(evidence.iterdir()):
            raise RuntimeError(f"output directory is not empty: {evidence}")
        evidence.mkdir(parents=True, exist_ok=True)
    workspace = evidence / "workspace"
    workspace.mkdir()

    git = shutil.which(os.environ.get("REIX_GIT", "git"))
    swift = shutil.which(os.environ.get("REIX_SWIFT", "swift"))
    if not git or not swift:
        raise RuntimeError("git and swift must be available")
    names = subprocess.check_output(
        [git, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=source,
    ).decode().split("\0")
    manifest = {}
    for name in names:
        if not name or not (source / name).is_file():
            continue
        destination = workspace / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, destination, follow_symlinks=False)
        manifest[name] = digest(destination)
    (evidence / "source-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )

    benchmark_source = workspace / "Tests/Benchmarks/BuddyAllocatorBenchmark.swift"
    injected = workspace / "Tests/KernelUnitTests/InjectedBuddyAllocatorBenchmark.swift"
    shutil.copy2(benchmark_source, injected)
    scratch = workspace / "build-host"
    command = [
        swift, "test", "--package-path", str(workspace), "--disable-sandbox",
        "--scratch-path", str(scratch), "-c", "release", "--no-parallel",
        "--filter", "BuddyAllocatorBenchmark",
    ]
    environment = {
        **os.environ,
        "FREESTANDING": "",
        "TERMINAL_PROFILE": "",
        "REIX_PERFORMANCE_GATES": "",
        "CLANG_MODULE_CACHE_PATH": str(evidence / "clang-module-cache"),
        "SWIFTPM_MODULECACHE_OVERRIDE": str(evidence / "swift-module-cache"),
        "REIX_BUDDY_BENCH_SAMPLES": str(args.samples),
    }
    log = evidence / "benchmark.log"
    with log.open("wb") as output:
        result = subprocess.run(
            command, cwd=workspace, env=environment,
            stdout=output, stderr=subprocess.STDOUT,
        )
    matches = re.findall(
        r"^" + re.escape(MARKER) + r"(.+)$",
        log.read_text(errors="replace"),
        re.MULTILINE,
    )
    if result.returncode != 0 or len(matches) != 1:
        raise RuntimeError(f"benchmark failed or emitted no unique marker; see {log}")
    raw = json.loads(matches[0])
    rows = []
    for row in raw["rows"]:
        elapsed = [int(value) for value in row["elapsed_ns"]]
        ops = int(row["ops"])
        rows.append({
            "workload": row["workload"],
            "pages": row["pages"],
            "ops": ops,
            "p50_total_ns": nearest_rank(elapsed, 0.50),
            "p50_ns_per_op": nearest_rank(elapsed, 0.50) / ops,
            "p95_ns_per_op": nearest_rank(elapsed, 0.95) / ops,
        })
    summary = {
        "scope": "host release build; BuddyAllocator over a host arena, no PPM",
        "target_claim": False,
        "sanitizer": "none",
        "command": command,
        "swift_version": subprocess.check_output([swift, "--version"], text=True).splitlines()[0],
        "source": str(benchmark_source),
        "source_sha256": digest(benchmark_source),
        "raw": raw,
        "rows": rows,
        "log": str(log),
    }
    (evidence / "result.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    print(f"evidence: {evidence}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError) as error:
        print(f"buddy-benchmark: {error}", file=sys.stderr)
        raise SystemExit(2)
