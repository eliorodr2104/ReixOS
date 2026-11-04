#!/usr/bin/env python3
"""Fault a stale translation in AArch64 QEMU, and prove the probe can tell.

The active checkout is only snapshotted. Each external build links the EL0
oracle in Tests/GuestProbes/TLBMaintenanceUser.S as init: it reads through a
translation right after a clone downgraded it and right after munmap removed
it, without a syscall in between that could switch address spaces.

QEMU's soft TLB caches translations and drops nothing it is not told to, so a
missing invalidation leaves a stale entry the oracle can hit. It ignores the
ASID of a by-address invalidation and flushes everything on an ASID switch,
so the tag an invalidation names is not what this proves: the disassembly
post-checks and the host recorder are. Each mutation removes one invalidation
from its snapshot and passes as a control only when the unchanged oracle
reports the stale access it left.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


TRIPLE = "aarch64-none-none-elf"
REIX = Path(__file__).resolve().parents[2] / "reix"

COW_PASS = "[ TLB COW PASS ]"
COW_FAIL = "[ TLB COW FAIL ]"
UNMAP_PROBE = "[ TLB UNMAP PROBE ]"
UNMAP_FAIL = "[ TLB UNMAP FAIL ]"
SETUP_FAIL = "[ TLB SETUP FAIL ]"
CHILD_FAULT = re.compile(r"\[SEGFAULT\] pid=2 far=0x[0-9a-fA-F]+ .*access=read")

# Each mutation is one exact source edit, refused if the text has moved.
MUTATIONS = {
    "candidate": None,
    "unmap-without-invalidation": (
        "Sources/Kernel/Memory/Virtual/Regions/PageRetirement.swift",
        "                Arch.MMU.flushTLBLeafNoSync(virtuals[index], asid: context.asid)\n",
        "",
    ),
    "clone-without-invalidation": (
        "Sources/Kernel/Memory/Virtual/Regions/VMAManager+Lifecycle.swift",
        "            Arch.MMU.flushTLB(asid: parent.context.asid)\n",
        "",
    ),
}


def tool(environment: str, fallback: str) -> str:
    candidate = os.environ.get(environment, fallback)
    resolved = shutil.which(candidate)
    if resolved is None:
        raise RuntimeError(f"{candidate!r} was not found; set {environment}")
    return resolved


def snapshot(source: Path, target: Path, git: str) -> None:
    names = subprocess.check_output(
        [git, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=source,
    ).decode().split("\0")

    for name in names:
        if not name:
            continue
        source_file = source / name
        if not source_file.is_file():
            continue
        target_file = target / name
        target_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_file, target_file, follow_symlinks=False)


def run_logged(command: list[str], *, cwd: Path, environment: dict[str, str], log: Path) -> None:
    with log.open("wb") as output:
        result = subprocess.run(command, cwd=cwd, env=environment, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        tail = log.read_text(errors="replace").splitlines()[-30:]
        raise RuntimeError(f"{' '.join(command)} failed ({result.returncode}); see {log}\n" + "\n".join(tail))


def replace_init(workspace: Path, output: Path, clang: str, llvm_ar: str, build_path: str, mode: str) -> None:
    source = workspace / "Tests/GuestProbes/TLBMaintenanceUser.S"
    object_file = output / f"tlb-{mode}.o"
    subprocess.run([clang, f"--target={TRIPLE}", "-c", str(source), "-o", str(object_file)], check=True)

    archive = workspace / build_path / TRIPLE / "debug" / "libInit.a"
    archive.unlink()
    subprocess.run([llvm_ar, "rcs", str(archive), str(object_file)], check=True)


def run_guest(*, mode: str, workspace: Path, output: Path, qemu: str, timeout: float) -> dict[str, object]:
    image = output / f"{mode}-kernel.bin"
    shutil.copy2(workspace / ".reix/kernel.bin", image)
    shutil.copy2(workspace / ".reix/kernel.elf", output / f"{mode}-kernel.elf")
    log = output / f"{mode}-serial.log"
    command = [
        qemu,
        "-machine", "virt,gic-version=2",
        "-cpu", "cortex-a53,pmu=on",
        "-nographic",
        "-m", "4M",
        "-kernel", str(image),
    ]

    started = time.monotonic()
    with log.open("wb") as output_file:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=output_file, stderr=subprocess.STDOUT)
        try:
            while time.monotonic() - started < timeout:
                data = log.read_text(errors="replace")
                done = (
                    UNMAP_FAIL in data or COW_FAIL in data or SETUP_FAIL in data
                    or CHILD_FAULT.search(data) is not None
                    or "REIX-PANIC" in data or "[ PANIC ]" in data
                    or process.poll() is not None
                )
                if done:
                    # A moment more, so a line that follows the deciding one lands.
                    time.sleep(0.3)
                    break
                time.sleep(0.05)
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

    data = log.read_text(errors="replace")
    observed = {
        "cowPass": COW_PASS in data,
        "cowFail": COW_FAIL in data,
        "unmapProbe": UNMAP_PROBE in data,
        "unmapFail": UNMAP_FAIL in data,
        "childFault": CHILD_FAULT.search(data) is not None,
        "setupFail": SETUP_FAIL in data,
        "panic": "REIX-PANIC" in data or "[ PANIC ]" in data,
    }

    if mode == "candidate":
        accepted = (
            observed["cowPass"] and observed["unmapProbe"] and observed["childFault"]
            and not observed["cowFail"] and not observed["unmapFail"]
            and not observed["setupFail"] and not observed["panic"]
        )
    elif mode == "unmap-without-invalidation":
        accepted = observed["cowPass"] and observed["unmapFail"] and not observed["childFault"]
    else:
        accepted = observed["cowFail"] and not observed["cowPass"]

    return {
        "mode": mode,
        "accepted": accepted,
        "observed": observed,
        "seconds": round(time.monotonic() - started, 2),
        "command": command,
        "log": str(log),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--modes", nargs="*", default=list(MUTATIONS))
    arguments = parser.parse_args()

    source = Path(__file__).resolve().parents[2]
    if arguments.output is None:
        evidence = Path(tempfile.mkdtemp(prefix="reix-tlb-maintenance-"))
    else:
        evidence = arguments.output.resolve()
        if evidence.exists() and any(evidence.iterdir()):
            raise RuntimeError(f"output directory is not empty: {evidence}")
        evidence.mkdir(parents=True, exist_ok=True)

    swift = tool("REIX_SWIFT", "swift")
    clang = tool("REIX_CLANG", "clang")
    llvm_ar = tool("REIX_LLVM_AR", "llvm-ar")
    qemu = tool("REIX_QEMU", "qemu-system-aarch64")
    git = tool("REIX_GIT", "git")

    results: list[dict[str, object]] = []

    for mode in arguments.modes:
        workspace = evidence / f"workspace-{mode}"
        workspace.mkdir()
        snapshot(source, workspace, git)

        mutation = MUTATIONS[mode]
        if mutation is not None:
            path, old, new = mutation
            target = workspace / path
            text = target.read_text()
            if text.count(old) != 1:
                raise RuntimeError(f"{mode}: the mutated line no longer matches {path}")
            target.write_text(text.replace(old, new))

        environment = {
            **os.environ,
            "SWIFT": swift,
            "FREESTANDING": "1",
            "CLANG_MODULE_CACHE_PATH": str(evidence / "module-cache-clang"),
            "SWIFTPM_MODULECACHE_OVERRIDE": str(evidence / "module-cache-swift"),
        }
        build_path = "build-cross"
        run_logged(
            [
                # Swift Build cannot build this triple from macOS; the Makefile `app`
                # target says why and when `native` can go.
                swift, "build", "--build-system", "native", "--disable-sandbox",
                "--triple", TRIPLE, "--scratch-path", build_path,
            ],
            cwd=workspace,
            environment=environment,
            log=evidence / f"{mode}-cross-build.log",
        )
        replace_init(workspace, evidence, clang, llvm_ar, build_path, mode)
        run_logged(
            [str(REIX), "build", "--no-compile"],
            cwd=workspace,
            environment={**environment, "REIX_BUILD_PATH": build_path},
            log=evidence / f"{mode}-link.log",
        )
        result = run_guest(mode=mode, workspace=workspace, output=evidence, qemu=qemu, timeout=arguments.timeout)
        results.append(result)
        print(json.dumps(result))

    summary = {"passed": all(bool(result["accepted"]) for result in results), "results": results}
    (evidence / "result.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"evidence: {evidence}")
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"tlb-maintenance: {error}", file=sys.stderr)
        raise SystemExit(2)
