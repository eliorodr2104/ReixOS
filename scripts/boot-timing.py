#!/usr/bin/env python3
"""Boot the built image N times and report kernel boot-phase timing robustly.

QEMU's TCG timing is noisy: one boot can land a phase twice as late as the
next for reasons that have nothing to do with the kernel. So every boot is
read through the kernel's own trace (the `bootPhase` events `reix trace
--boot` decodes, the same ones the `trace-boot` scenario checks), and each
phase is summarised by its median and its median absolute deviation (MAD)
after dropping the samples further than 3 MAD from the median.

Two result files compare phase by phase. A change is reported only when the
medians differ by more than 3 MAD of the noisier run; anything smaller is
called indistinguishable from noise, which is what most single runs are.

The image must be a diagnostic build (`make vm-test`, or `make programs
BOOT_MODE=diagnostic`), the only mode whose init dumps the trace ring. This
script builds nothing and is not part of `make test`.

Usage:
    scripts/boot-timing.py [--runs 9] [--mem 4M] [--output result.json]
    scripts/boot-timing.py --compare before.json after.json

Environment: QEMU, QEMU_FLAGS, OUT, DISK, as scripts/smoke.sh reads them.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile


# The decoder prints milliseconds to two decimals, so no spread is finer.
RESOLUTION_MS = 0.01
REJECT_MADS = 3.0
ROW = re.compile(r"^\s+(\w+)\s+([0-9.]+)\s+([0-9.]+)\s*$")


def fail(message: str) -> None:
    raise RuntimeError(message)


def boot_once(root: Path, log: Path, mem: str, initrd: str, timeout: int) -> None:
    out = os.environ.get("OUT", ".reix")
    disk = os.environ.get("DISK", f"{out}/disk.img")
    base = "-machine virt,gic-version=2 -cpu cortex-a53,pmu=on -nographic"
    flags = os.environ.get(
        "QEMU_FLAGS",
        f"{base} -drive file={disk},if=none,format=raw,id=reixdisk "
        "-device virtio-blk-device,drive=reixdisk",
    )
    environment = {
        **os.environ,
        "QEMU_FLAGS": flags,
        "MEM": mem,
        "INITRD_MODE": initrd,
        "LOG": str(log),
        "TIMEOUT": str(timeout),
        "SUCCESS_MARKER": "[TRACE] end",
    }
    result = subprocess.run(
        ["sh", "scripts/smoke.sh"], cwd=root, env=environment,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    if result.returncode != 0:
        fail(f"boot did not reach the trace dump ({log}):\n{result.stdout.strip()}")


def phases_of(root: Path, log: Path) -> dict[str, float]:
    decoded = subprocess.run(
        [str(root / "reix"), "trace", str(log), "--boot"], cwd=root,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    if decoded.returncode != 0:
        fail(f"reix trace --boot failed on {log}")

    phases: dict[str, float] = {}
    total = None
    inside = False
    for line in decoded.stdout.splitlines():
        if line.startswith("Boot phases:"):
            inside = True
        elif inside and not line.strip():
            break
        elif inside and (match := ROW.match(line)):
            # Per-phase cost is the delta to the previous phase; the absolute
            # time of the last one is the whole traced boot.
            phases[match.group(1)] = float(match.group(3))
            total = float(match.group(2))
    if total is None:
        fail(f"no boot phases decoded from {log}")
    phases["total"] = total
    return phases


def summarise(samples: list[float]) -> dict:
    median = statistics.median(samples)
    mad = max(statistics.median(abs(x - median) for x in samples), RESOLUTION_MS)
    kept = [x for x in samples if abs(x - median) <= REJECT_MADS * mad]
    median = statistics.median(kept)
    mad = max(statistics.median(abs(x - median) for x in kept), RESOLUTION_MS)
    return {
        "median_ms": round(median, 3),
        "mad_ms": round(mad, 3),
        "min_ms": min(kept),
        "max_ms": max(kept),
        "kept": len(kept),
        "samples": samples,
    }


def measure(args: argparse.Namespace) -> int:
    root = Path(__file__).resolve().parent.parent
    evidence = Path(tempfile.mkdtemp(prefix="reix-boot-timing-"))
    initrd = args.initrd or ("embedded" if args.mem == "4M" else "qemu")

    runs: list[dict[str, float]] = []
    for index in range(args.runs):
        log = evidence / f"boot-{index + 1}.log"
        boot_once(root, log, args.mem, initrd, args.timeout)
        runs.append(phases_of(root, log))
        print(f"boot {index + 1}/{args.runs}: total {runs[-1]['total']:.2f} ms", file=sys.stderr)

    names = list(runs[0])
    for run in runs[1:]:
        if list(run) != names:
            fail("boots decoded different phase lists; is the image the same?")

    result = {
        "mem": args.mem or "default",
        "initrd": initrd,
        "runs": args.runs,
        "reject_beyond_mads": REJECT_MADS,
        "logs": str(evidence),
        "phases": {name: summarise([run[name] for run in runs]) for name in names},
    }
    if args.output:
        args.output.write_text(json.dumps(result, indent=2) + "\n")

    print(f"boot timing, {args.runs} boots, mem={result['mem']}, initrd={initrd} (ms)")
    print(f"{'phase':<14} {'median':>8} {'MAD':>7} {'min':>8} {'max':>8} {'kept':>5}")
    for name, stats in result["phases"].items():
        print(f"{name:<14} {stats['median_ms']:>8.2f} {stats['mad_ms']:>7.2f} "
              f"{stats['min_ms']:>8.2f} {stats['max_ms']:>8.2f} {stats['kept']:>3}/{args.runs}")
    print(f"logs: {evidence}")
    return 0


def compare(before_path: Path, after_path: Path) -> int:
    before = json.loads(before_path.read_text())
    after = json.loads(after_path.read_text())
    if (before["mem"], before["initrd"]) != (after["mem"], after["initrd"]):
        fail("the two results booted different machines")

    print(f"boot timing delta, mem={after['mem']} (ms; a change must exceed "
          f"{REJECT_MADS:g} MAD of the noisier run)")
    print(f"{'phase':<14} {'before':>8} {'after':>8} {'delta':>8} {'spread':>7}  verdict")
    for name, old in before["phases"].items():
        new = after["phases"].get(name)
        if new is None:
            print(f"{name:<14} missing from {after_path}")
            continue
        delta = new["median_ms"] - old["median_ms"]
        spread = REJECT_MADS * max(old["mad_ms"], new["mad_ms"])
        verdict = (f"{'slower' if delta > 0 else 'faster'} by {abs(delta):.2f}"
                   if abs(delta) > spread else "indistinguishable from noise")
        print(f"{name:<14} {old['median_ms']:>8.2f} {new['median_ms']:>8.2f} "
              f"{delta:>+8.2f} {spread:>7.2f}  {verdict}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--runs", type=int, default=9)
    parser.add_argument("--mem", default="", help="guest RAM, e.g. 4M (default: machine default)")
    parser.add_argument("--initrd", choices=["qemu", "embedded"],
                        help="default: embedded at 4M, qemu otherwise")
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--compare", nargs=2, type=Path, metavar=("BEFORE", "AFTER"))
    args = parser.parse_args()

    if args.compare:
        return compare(*args.compare)
    if args.runs < 3:
        fail("runs must be at least three for a median and a MAD to mean anything")
    return measure(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError, KeyError) as error:
        print(f"boot-timing: {error}", file=sys.stderr)
        raise SystemExit(2)
