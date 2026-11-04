"""Exercise the vector gate against real, minimal AArch64 ELF images."""

import contextlib
import importlib.util
import io
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "vector_gate", ROOT / "scripts/gate/check-vector-primitives.py"
)
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class VectorPrimitiveGateTests(unittest.TestCase):
    def check_image(self, body, orphan=""):
        clang = shutil.which("clang")
        linker = shutil.which("ld.lld")
        objdump = shutil.which("llvm-objdump")
        self.assertTrue(clang and linker and objdump, "the project LLVM tools are required")
        assembly = """
.text
.globl memcpy
.type memcpy, %function
memcpy:
    ret
.size memcpy, .-memcpy
.globl memmove
.type memmove, %function
memmove:
""" + body + "\n.size memmove, .-memmove\n" + orphan + """
.globl free
.type free, %function
free:
    b memcpy
.size free, .-free
"""
        with tempfile.TemporaryDirectory(prefix="reix-vector-gate-") as temporary:
            directory = Path(temporary)
            source = directory / "probe.S"
            source.write_text(assembly)
            subprocess.run([clang, "--target=aarch64-none-elf", "-c", str(source),
                            "-o", str(directory / "probe.o")], check=True, capture_output=True)
            subprocess.run([linker, "-Ttext=0x210000", "--entry=memmove",
                            str(directory / "probe.o"), "-o", str(directory / "probe.elf")],
                           check=True)
            with contextlib.redirect_stdout(io.StringIO()):
                return GATE.check(objdump, str(directory / "probe.elf"), kernel=False)

    def test_unlabelled_code_after_function_end_is_not_a_callee(self):
        self.assertIsNone(self.check_image("    ret", "    b free\n"))

    def test_real_tail_call_to_another_primitive_is_rejected(self):
        self.assertIn("memmove reaches memcpy", self.check_image("    b free"))

    def test_reachable_block_after_an_early_return_is_still_checked(self):
        body = "    cbz x0, .Llate\n    ret\n.Llate:\n    b free"
        self.assertIn("memmove reaches memcpy", self.check_image(body))

    def test_direct_recursion_is_rejected(self):
        self.assertIn("reaches itself", self.check_image("    bl memmove\n    ret"))

    def test_indirect_calls_are_rejected(self):
        self.assertIn("indirect call", self.check_image("    blr x3\n    ret"))

    def test_branch_to_anonymous_indirect_call_is_rejected(self):
        self.assertIn("indirect call", self.check_image(
            "    b .Loutside", ".Loutside:\n    blr x3\n    ret\n"))

    def test_branch_to_anonymous_primitive_call_is_rejected(self):
        self.assertIn("memmove reaches memcpy", self.check_image(
            "    b .Loutside", ".Loutside:\n    b free\n"))

    def test_fallthrough_to_anonymous_indirect_call_is_rejected(self):
        self.assertIn("indirect call", self.check_image(
            "    nop", "    blr x3\n    ret\n"))

    def test_unreachable_anonymous_zva_is_still_rejected_in_programs(self):
        self.assertIn("a program holds dc zva", self.check_image(
            "    ret", "    dc zva, x0\n    ret\n"))


if __name__ == "__main__":
    unittest.main()
