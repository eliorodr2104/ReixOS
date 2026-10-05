#!/usr/bin/env python3
"""Build and run the first-user-stack zeroing oracle on AArch64 QEMU.

The active checkout is only snapshotted. In each external build the kernel first
fills one frame with 0xA5, releases it, proves that the stack allocation got the
same physical frame and that its final byte still carries the poison, then takes
the normal publication path. A raw EL0 `_start` scans all 4096 stack bytes before
any instruction uses the stack.

The negative control removes only the candidate zeroing from its snapshot. It
passes as a control only when the unchanged EL0 oracle reports a nonzero byte.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


TRIPLE = "aarch64-none-none-elf"
MODES = ("candidate", "mutation")
PASS_MARKER = "[ PAGE ZERO PASS ] bytes=4096"
FAIL_MARKER = "[ PAGE ZERO FAIL ] nonzero-stack-byte"


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


def snapshot_manifest(root: Path) -> dict[str, str]:
    return {
        str(path.relative_to(root)): sha256(path)
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


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


def instrument_process_manager(source: str, *, omit_zeroing: bool) -> str:
    allocation = """                let stackPage: PhysicalPage
                do {
                    stackPage = try ppm.pointee.alloc(4096)
                } catch {
                    destroyPartialAddressSpace(&addressSpace)
                    throw .allocationPageFailed(error)
                }

"""
    if source.count(allocation) != 1:
        raise RuntimeError("stack allocation site no longer matches the diagnostic")

    poison = """                let diagnosticPage: PhysicalPage
                do {
                    diagnosticPage = try ppm.pointee.alloc(4096)
                } catch {
                    Arch.CPU.panic("page-zero diagnostic could not allocate poison frame")
                }

                let diagnosticBytes: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(
                    diagnosticPage.address
                )
                diagnosticBytes.initialize(
                    repeating: 0xA5,
                    count    : Int(UserSpaceLayout.pageSize)
                )

                do {
                    try ppm.pointee.release(diagnosticPage.address)
                } catch {
                    Arch.CPU.panic("page-zero diagnostic could not recycle poison frame")
                }

"""
    verify = """                guard stackPage.address == diagnosticPage.address else {
                    Arch.CPU.panic("page-zero diagnostic did not recycle poison frame")
                }
                guard diagnosticBytes[Int(UserSpaceLayout.pageSize) - 1] == 0xA5 else {
                    Arch.CPU.panic("page-zero diagnostic poison was not preserved")
                }

"""
    source = source.replace(allocation, poison + allocation + verify)

    zeroing = """                let stackBytes: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(
                    stackPage.address
                )
                stackBytes.initialize(
                    repeating: 0,
                    count    : Int(UserSpaceLayout.pageSize)
                )

"""
    if source.count(zeroing) != 1:
        raise RuntimeError("candidate stack zeroing no longer matches the diagnostic")
    if omit_zeroing:
        source = source.replace(zeroing, "")

    return source


def replace_init(
    workspace: Path,
    output: Path,
    clang: str,
    llvm_ar: str,
    build_path: str,
    mode: str,
) -> None:
    source = workspace / "Tests/GuestProbes/PageZeroingUser.S"
    object_file = output / f"page-zero-{mode}.o"
    subprocess.run(
        [clang, f"--target={TRIPLE}", "-c", str(source), "-o", str(object_file)],
        check=True,
    )

    archive = workspace / build_path / TRIPLE / "debug" / "libInit.a"
    archive.unlink()
    subprocess.run([llvm_ar, "rcs", str(archive), str(object_file)], check=True)


def run_guest(
    *,
    mode: str,
    workspace: Path,
    output: Path,
    qemu: str,
    timeout: float,
) -> dict[str, object]:
    image = workspace / ".reix/kernel.bin"
    elf = workspace / ".reix/kernel.elf"
    archived_image = output / f"{mode}-kernel.bin"
    archived_elf = output / f"{mode}-kernel.elf"
    shutil.copy2(image, archived_image)
    shutil.copy2(elf, archived_elf)
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
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=output_file,
            stderr=subprocess.STDOUT,
        )
        try:
            while time.monotonic() - started < timeout:
                data = log.read_text(errors="replace")
                if (
                    PASS_MARKER in data
                    or FAIL_MARKER in data
                    or "REIX-PANIC" in data
                    or "[ PANIC ]" in data
                    or process.poll() is not None
                ):
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
    observed_pass = PASS_MARKER in data
    observed_failure = FAIL_MARKER in data
    panicked = "REIX-PANIC" in data or "[ PANIC ]" in data
    accepted = (
        observed_pass and not observed_failure and not panicked
        if mode == "candidate"
        else observed_failure and not observed_pass and not panicked
    )
    return {
        "mode": mode,
        "accepted": accepted,
        "observedPass": observed_pass,
        "observedFailure": observed_failure,
        "panic": panicked,
        "seconds": time.monotonic() - started,
        "command": command,
        "log": str(log),
        "kernel": str(archived_image),
        "kernelELF": str(archived_elf),
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=float, default=30)
    arguments = parser.parse_args()

    source = Path(__file__).resolve().parent.parent
    if arguments.output is None:
        evidence = Path(tempfile.mkdtemp(prefix="reix-page-zeroing-"))
    else:
        evidence = arguments.output.resolve()
        if evidence.exists() and any(evidence.iterdir()):
            raise RuntimeError(f"output directory is not empty: {evidence}")
        evidence.mkdir(parents=True, exist_ok=True)

    workspace = evidence / "workspace"
    workspace.mkdir()

    swift = tool("REIX_SWIFT", "swift")
    clang = tool("REIX_CLANG", "clang")
    llvm_ar = tool("REIX_LLVM_AR", "llvm-ar")
    qemu = tool("REIX_QEMU", "qemu-system-aarch64")
    git = tool("REIX_GIT", "git")
    snapshot(source, workspace, git)
    initial_manifest = snapshot_manifest(workspace)
    manifest_path = evidence / "initial-manifest.json"
    manifest_path.write_text(json.dumps(initial_manifest, indent=2) + "\n")

    process_manager = workspace / "Sources/ReixKernel/Process/ProcessManager.swift"
    original = process_manager.read_text()
    environment = {
        **os.environ,
        "FREESTANDING": "1",
        "CLANG_MODULE_CACHE_PATH": str(evidence / "module-cache-clang"),
        "SWIFTPM_MODULECACHE_OVERRIDE": str(evidence / "module-cache-swift"),
    }
    results: list[dict[str, object]] = []

    for mode in MODES:
        process_manager.write_text(
            instrument_process_manager(original, omit_zeroing=mode == "mutation")
        )
        instrumented_source = evidence / f"{mode}-ProcessManager.swift"
        shutil.copy2(process_manager, instrumented_source)
        build_path = f"build-cross-{mode}"
        run_logged(
            [
                swift, "build", "--disable-sandbox", "--triple", TRIPLE,
                "--scratch-path", build_path,
            ],
            cwd=workspace,
            environment=environment,
            log=evidence / f"{mode}-cross-build.log",
        )
        replace_init(workspace, evidence, clang, llvm_ar, build_path, mode)
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
        result = run_guest(
            mode=mode,
            workspace=workspace,
            output=evidence,
            qemu=qemu,
            timeout=arguments.timeout,
        )
        result["instrumentedProcessManager"] = str(instrumented_source)
        result["instrumentedProcessManagerSHA256"] = sha256(instrumented_source)
        results.append(result)
        print(json.dumps(result))

    identity_paths = [
        "Sources/ReixKernel/Process/ProcessManager.swift",
        "Tests/GuestProbes/PageZeroingUser.S",
        "scripts/test-page-zeroing.py",
    ]
    summary = {
        "passed": all(bool(result["accepted"]) for result in results),
        "workspace": str(workspace),
        "initialManifest": str(manifest_path),
        "sourceIdentity": {
            path: initial_manifest[path] for path in identity_paths
        },
        "results": results,
    }
    (evidence / "result.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"evidence: {evidence}")
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"page-zeroing: {error}", file=sys.stderr)
        raise SystemExit(2)
