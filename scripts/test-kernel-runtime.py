#!/usr/bin/env python3
"""Exercise the T05 runtime ABI and its exact failure oracles in AArch64 QEMU.

All builds happen in a snapshot outside the checkout. The lifecycle diagnostic
uses the real C symbols, UnsafeMutableRawPointer allocation/deallocation, Hasher
initialization, and exact PMM page restoration. ARC-managed kernel objects are
outside this contract because Embedded Swift reserves the high pointer bit that
the kernel direct map uses. The stack diagnostic corrupts a compiler-saved guard
in an object built with -fstack-protector-all. Two runtime mutations prove that
retained pages and a changed panic reason are rejected by their intended oracles.
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
import time


TRIPLE = "aarch64-none-none-elf"
PASS_PREFIX = "[ RUNTIME ABI PASS ] hash=0x"
PAGE_FAILURE = "runtime ABI diagnostic: heap pages not restored"
STACK_FAILURE = "stack protector: kernel stack corruption detected"
STACK_MUTATION = "stack protector: MUTATED diagnostic reason"
STACK_FALLBACK = "runtime ABI diagnostic: stack check returned"


def tool(environment: str, fallback: str) -> str:
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


def run_logged(
    command: list[str],
    *,
    cwd: Path,
    environment: dict[str, str],
    log: Path,
) -> None:
    with log.open("wb") as output:
        result = subprocess.run(
            command,
            cwd=cwd,
            env=environment,
            stdout=output,
            stderr=subprocess.STDOUT,
        )
    if result.returncode != 0:
        tail = log.read_text(errors="replace").splitlines()[-30:]
        raise RuntimeError(
            f"{' '.join(command)} failed ({result.returncode}); see {log}\n"
            + "\n".join(tail)
        )


def build_and_link(
    *,
    mode: str,
    workspace: Path,
    evidence: Path,
    swift: str,
    base_environment: dict[str, str],
    diagnostic: str,
    build_path: str,
) -> None:
    environment = {**base_environment, diagnostic: "1"}
    run_logged(
        [
            swift, "build", "--disable-sandbox", "--triple", TRIPLE,
            "--scratch-path", build_path,
        ],
        cwd=workspace,
        environment=environment,
        log=evidence / f"{mode}-cross-build.log",
    )
    run_logged(
        [
            swift, "package", "--disable-sandbox",
            "--scratch-path", f"build-plugin-{mode}",
            "--allow-writing-to-package-directory", "reix",
        ],
        cwd=workspace,
        environment={**environment, "REIX_BUILD_PATH": build_path},
        log=evidence / f"{mode}-link.log",
    )


def run_guest(
    *,
    mode: str,
    workspace: Path,
    evidence: Path,
    qemu: str,
    timeout: float,
    stop_markers: tuple[str, ...],
) -> tuple[str, dict[str, object]]:
    image = workspace / ".reix/kernel.bin"
    elf = workspace / ".reix/kernel.elf"
    archived_image = evidence / f"{mode}-kernel.bin"
    archived_elf = evidence / f"{mode}-kernel.elf"
    shutil.copy2(image, archived_image)
    shutil.copy2(elf, archived_elf)
    log = evidence / f"{mode}-serial.log"
    command = [
        qemu,
        "-machine", "virt,gic-version=2",
        "-cpu", "cortex-a53,pmu=on",
        "-nographic",
        "-m", "4M",
        "-kernel", str(image),
    ]

    started = time.monotonic()
    with log.open("wb") as output:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=subprocess.STDOUT,
        )
        try:
            while time.monotonic() - started < timeout:
                serial = log.read_text(errors="replace")
                if any(marker in serial for marker in stop_markers):
                    break
                if process.poll() is not None:
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

    serial = log.read_text(errors="replace")
    return serial, {
        "mode": mode,
        "seconds": time.monotonic() - started,
        "command": command,
        "serialLog": str(log),
        "kernel": str(archived_image),
        "kernelSHA256": sha256(archived_image),
        "kernelELF": str(archived_elf),
        "kernelELFSHA256": sha256(archived_elf),
    }


def replace_once(source: str, old: str, new: str, description: str) -> str:
    if source.count(old) != 1:
        raise RuntimeError(f"{description} mutation expected one source match")
    return source.replace(old, new)


def archive_stack_object(
    workspace: Path,
    evidence: Path,
    mode: str,
    objdump: str,
) -> dict[str, str]:
    matches = list((workspace / f"build-plugin-{mode}").rglob("KernelRuntimeProbe.c.o"))
    if len(matches) != 1:
        raise RuntimeError(f"expected one stack diagnostic object, found {len(matches)}")
    archived = evidence / f"{mode}-KernelRuntimeProbe.c.o"
    shutil.copy2(matches[0], archived)
    disassembly = evidence / f"{mode}-KernelRuntimeProbe.objdump.txt"
    with disassembly.open("wb") as output:
        subprocess.run([objdump, "-dr", str(archived)], check=True, stdout=output)
    text = disassembly.read_text(errors="replace")
    if "__stack_chk_guard" not in text or "__stack_chk_fail" not in text:
        raise RuntimeError("diagnostic object lacks compiler-emitted stack protector references")
    return {
        "object": str(archived),
        "objectSHA256": sha256(archived),
        "disassembly": str(disassembly),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=float, default=30)
    arguments = parser.parse_args()

    source = Path(__file__).resolve().parent.parent
    evidence = (
        arguments.output.resolve()
        if arguments.output
        else Path(tempfile.mkdtemp(prefix="reix-kernel-runtime-"))
    )
    if arguments.output:
        if evidence.exists() and any(evidence.iterdir()):
            raise RuntimeError(f"output directory is not empty: {evidence}")
        evidence.mkdir(parents=True, exist_ok=True)

    workspace = evidence / "workspace"
    workspace.mkdir()
    swift = tool("REIX_SWIFT", "swift")
    qemu = tool("REIX_QEMU", "qemu-system-aarch64")
    git = tool("REIX_GIT", "git")
    objdump = tool("REIX_OBJDUMP", "llvm-objdump")
    manifest = snapshot(source, workspace, git)
    manifest_path = evidence / "initial-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

    base_environment = {
        **os.environ,
        "FREESTANDING": "1",
        "CLANG_MODULE_CACHE_PATH": str(evidence / "module-cache-clang"),
        "SWIFTPM_MODULECACHE_OVERRIDE": str(evidence / "module-cache-swift"),
    }
    stubs = workspace / "Sources/ReixKernel/Core/Stubs.swift"
    original_stubs = stubs.read_text()
    results: list[dict[str, object]] = []

    build_and_link(
        mode="lifecycle-candidate",
        workspace=workspace,
        evidence=evidence,
        swift=swift,
        base_environment=base_environment,
        diagnostic="REIX_RUNTIME_DIAGNOSTIC",
        build_path="build-cross-runtime",
    )
    candidate_serial, candidate = run_guest(
        mode="lifecycle-candidate",
        workspace=workspace,
        evidence=evidence,
        qemu=qemu,
        timeout=arguments.timeout,
        stop_markers=(PASS_PREFIX, PAGE_FAILURE, "=== REIX-PANIC END"),
    )
    hashes = re.findall(r"\[ RUNTIME ABI PASS \] hash=0x([0-9A-Fa-f]+)", candidate_serial)
    candidate["accepted"] = (
        len(hashes) == 1
        and "REIX-PANIC" not in candidate_serial
        and "[ PANIC ]" not in candidate_serial
    )
    candidate["hash"] = hashes[0] if len(hashes) == 1 else None
    results.append(candidate)

    repeat_serial, repeat = run_guest(
        mode="lifecycle-repeat",
        workspace=workspace,
        evidence=evidence,
        qemu=qemu,
        timeout=arguments.timeout,
        stop_markers=(PASS_PREFIX, PAGE_FAILURE, "=== REIX-PANIC END"),
    )
    repeat_hashes = re.findall(r"\[ RUNTIME ABI PASS \] hash=0x([0-9A-Fa-f]+)", repeat_serial)
    repeat["hash"] = repeat_hashes[0] if len(repeat_hashes) == 1 else None
    repeat["accepted"] = (
        len(repeat_hashes) == 1
        and repeat["hash"] == candidate["hash"]
        and "REIX-PANIC" not in repeat_serial
        and "[ PANIC ]" not in repeat_serial
    )
    results.append(repeat)

    free_call = "    heap.pointee.kfree(pointer)\n"
    stubs.write_text(replace_once(
        original_stubs,
        free_call,
        "    _ = heap // T05 negative control: deliberately retain the allocation.\n",
        "free",
    ))
    build_and_link(
        mode="free-mutation",
        workspace=workspace,
        evidence=evidence,
        swift=swift,
        base_environment=base_environment,
        diagnostic="REIX_RUNTIME_DIAGNOSTIC",
        build_path="build-cross-runtime",
    )
    mutation_serial, mutation = run_guest(
        mode="free-mutation",
        workspace=workspace,
        evidence=evidence,
        qemu=qemu,
        timeout=arguments.timeout,
        stop_markers=(PAGE_FAILURE, PASS_PREFIX, "=== REIX-PANIC END"),
    )
    mutation["accepted"] = PAGE_FAILURE in mutation_serial and PASS_PREFIX not in mutation_serial
    results.append(mutation)

    stubs.write_text(original_stubs)
    build_and_link(
        mode="stack-candidate",
        workspace=workspace,
        evidence=evidence,
        swift=swift,
        base_environment=base_environment,
        diagnostic="REIX_RUNTIME_STACK_DIAGNOSTIC",
        build_path="build-cross-stack",
    )
    stack_object = archive_stack_object(workspace, evidence, "stack-candidate", objdump)
    stack_serial, stack = run_guest(
        mode="stack-candidate",
        workspace=workspace,
        evidence=evidence,
        qemu=qemu,
        timeout=arguments.timeout,
        stop_markers=(STACK_FAILURE, STACK_FALLBACK, "=== REIX-PANIC END"),
    )
    stack["accepted"] = STACK_FAILURE in stack_serial and STACK_FALLBACK not in stack_serial
    stack["compilerProtectedObject"] = stack_object
    results.append(stack)

    stubs.write_text(replace_once(
        original_stubs,
        f'Arch.CPU.panic("{STACK_FAILURE}")',
        f'Arch.CPU.panic("{STACK_MUTATION}")',
        "stack reason",
    ))
    build_and_link(
        mode="stack-reason-mutation",
        workspace=workspace,
        evidence=evidence,
        swift=swift,
        base_environment=base_environment,
        diagnostic="REIX_RUNTIME_STACK_DIAGNOSTIC",
        build_path="build-cross-stack",
    )
    reason_serial, reason = run_guest(
        mode="stack-reason-mutation",
        workspace=workspace,
        evidence=evidence,
        qemu=qemu,
        timeout=arguments.timeout,
        stop_markers=(STACK_MUTATION, STACK_FAILURE, STACK_FALLBACK, "=== REIX-PANIC END"),
    )
    reason["accepted"] = (
        STACK_MUTATION in reason_serial
        and STACK_FAILURE not in reason_serial
        and STACK_FALLBACK not in reason_serial
    )
    results.append(reason)

    identity_paths = [
        "Sources/ReixKernel/Core/Stubs.swift",
        "Sources/ReixKernel/Diagnostics/KernelRuntimeDiagnostic.swift",
        "Native/kernel/KernelRuntimeABI.c",
        "Tests/GuestProbes/KernelRuntimeProbe.c",
        "scripts/test-kernel-runtime.py",
    ]
    summary = {
        "passed": all(bool(result["accepted"]) for result in results),
        "target": "AArch64 QEMU virt, 4 MiB RAM",
        "physicalHardwareTested": False,
        "workspace": str(workspace),
        "initialManifest": str(manifest_path),
        "sourceIdentity": {path: manifest[path] for path in identity_paths},
        "results": results,
    }
    (evidence / "result.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    print(f"evidence: {evidence}")
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"kernel-runtime: {error}", file=sys.stderr)
        raise SystemExit(2)
