#!/usr/bin/env python3
"""Generate allocation-free Swift Unicode 16 lookup tables from pinned UCD files."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


EXPECTED_SHA256 = {
    "DerivedCoreProperties.txt": "39d35161f2954497f69e08bdb9e701493f476a3d30222de20028feda36c1dabd",
    "EastAsianWidth.txt": "43adc76c0686a42cb370764eb8cfe2b2a45b10b855e5572a2db4a0eecce15d5b",
    "GraphemeBreakProperty.txt": "c29360bd6f7132811d701d29069541e827eb44bfc4c8fbde8c370d6982689dc1",
    "PropList.txt": "53d614508e2a0b2305a8aa21cd60d993de9326cdf65993660dfcce4503548583",
    "UnicodeData.txt": "ff58e5823bd095166564a006e47d111130813dcf8bf234ef79fa51a870edb48f",
    "emoji-data.txt": "f1365a5173eee18e1f98b240cdc492e84a25f1ce7e0c9d1094eb29c41a22696a",
}


def parse_range(text: str) -> tuple[int, int]:
    pieces = text.strip().split("..", 1)
    start = int(pieces[0], 16)
    return start, int(pieces[1], 16) if len(pieces) == 2 else start


def property_rows(path: Path) -> list[tuple[tuple[int, int], list[str]]]:
    rows = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        body = raw.split("#", 1)[0].strip()
        if not body or ";" not in body:
            continue
        fields = [field.strip() for field in body.split(";")]
        rows.append((parse_range(fields[0]), fields[1:]))
    return rows


def merge(ranges: list[tuple[int, int]]) -> list[tuple[int, int]]:
    result: list[list[int]] = []
    for start, end in sorted(ranges):
        if result and start <= result[-1][1] + 1:
            result[-1][1] = max(result[-1][1], end)
        else:
            result.append([start, end])
    return [(start, end) for start, end in result]


def unicode_categories(path: Path) -> dict[str, list[tuple[int, int]]]:
    result: dict[str, list[tuple[int, int]]] = {}
    pending: tuple[int, str, int] | None = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        fields = raw.split(";")
        scalar = int(fields[0], 16)
        name = fields[1]
        category = fields[2]
        combining = int(fields[3])
        if name.endswith(", First>"):
            pending = (scalar, category, combining)
            continue
        if name.endswith(", Last>"):
            assert pending is not None and pending[1:] == (category, combining)
            start = pending[0]
            pending = None
        else:
            start = scalar
        result.setdefault(category, []).append((start, scalar))
        if combining != 0:
            result.setdefault("Canonical_Combining", []).append((start, scalar))
    assert pending is None
    return {name: merge(ranges) for name, ranges in result.items()}


def swift_range(item: tuple[int, int]) -> str:
    start, end = item
    if start == end:
        return f"0x{start:04X}"
    return f"0x{start:04X}...0x{end:04X}"


def case_lines(ranges: list[tuple[int, int]], result: str) -> list[str]:
    lines = []
    items = [swift_range(item) for item in ranges]
    for offset in range(0, len(items), 6):
        prefix = "case " if offset == 0 else "     "
        suffix = ":" if offset + 6 >= len(items) else ","
        lines.append("        " + prefix + ", ".join(items[offset:offset + 6]) + suffix)
    lines.append(f"            return {result}")
    return lines


def boolean_function(name: str, ranges: list[tuple[int, int]]) -> list[str]:
    lines = [f"    static func {name}(_ value: UInt32) -> Bool {{", "        switch value {"]
    lines += case_lines(merge(ranges), result="true")
    lines += ["            default: return false", "        }", "    }"]
    return lines


def verify(directory: Path) -> None:
    for name, expected in EXPECTED_SHA256.items():
        path = directory / name
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != expected:
            raise SystemExit(f"{name}: expected {expected}, found {actual}")


def generate(directory: Path) -> str:
    verify(directory)
    gcb: dict[str, list[tuple[int, int]]] = {}
    for codepoints, fields in property_rows(directory / "GraphemeBreakProperty.txt"):
        gcb.setdefault(fields[0], []).append(codepoints)

    incb: dict[str, list[tuple[int, int]]] = {}
    derived: dict[str, list[tuple[int, int]]] = {}
    for codepoints, fields in property_rows(directory / "DerivedCoreProperties.txt"):
        if fields[0] == "InCB":
            incb.setdefault(fields[1], []).append(codepoints)
        else:
            derived.setdefault(fields[0], []).append(codepoints)

    eaw: dict[str, list[tuple[int, int]]] = {}
    for codepoints, fields in property_rows(directory / "EastAsianWidth.txt"):
        eaw.setdefault(fields[0], []).append(codepoints)

    emoji: dict[str, list[tuple[int, int]]] = {}
    for codepoints, fields in property_rows(directory / "emoji-data.txt"):
        emoji.setdefault(fields[0], []).append(codepoints)

    props: dict[str, list[tuple[int, int]]] = {}
    for codepoints, fields in property_rows(directory / "PropList.txt"):
        props.setdefault(fields[0], []).append(codepoints)

    categories = unicode_categories(directory / "UnicodeData.txt")
    zero_width = (
        gcb.get("Extend", [])
        + gcb.get("ZWJ", [])
        + gcb.get("Control", [])
        + gcb.get("CR", [])
        + gcb.get("LF", [])
        + categories.get("Mn", [])
        + categories.get("Me", [])
        + categories.get("Cf", [])
        + derived.get("Default_Ignorable_Code_Point", [])
        + props.get("Variation_Selector", [])
    )
    combining = categories.get("Canonical_Combining", []) + categories.get("Mn", []) + categories.get("Me", [])

    hashes = "\n".join(f"// {name}: {digest}" for name, digest in EXPECTED_SHA256.items())
    lines = [
        "// Generated by scripts/generate-unicode16-tables.py. Do not edit.",
        "// Unicode 16.0.0, allocation-free compressed scalar ranges.",
        hashes,
        "",
        "enum ReixUnicode16Tables {",
        "    enum GraphemeBreak: UInt8 {",
        "        case other, cr, lf, control, extend, zwj, regionalIndicator",
        "        case prepend, spacingMark, l, v, t, lv, lvt",
        "    }",
        "",
        "    enum IndicConjunct: UInt8 { case none, linker, consonant, extend }",
        "",
        "    static func graphemeBreak(_ value: UInt32) -> GraphemeBreak {",
        "        if value >= 0xAC00 && value <= 0xD7A3 {",
        "            return (value - 0xAC00) % 28 == 0 ? .lv : .lvt",
        "        }",
        "        switch value {",
    ]
    gcb_mapping = [
        ("CR", ".cr"), ("LF", ".lf"), ("Control", ".control"),
        ("Extend", ".extend"), ("ZWJ", ".zwj"),
        ("Regional_Indicator", ".regionalIndicator"), ("Prepend", ".prepend"),
        ("SpacingMark", ".spacingMark"), ("L", ".l"), ("V", ".v"), ("T", ".t"),
    ]
    for source, target in gcb_mapping:
        lines += case_lines(merge(gcb.get(source, [])), target)
    lines += ["            default: return .other", "        }", "    }", ""]

    lines += ["    static func indicConjunct(_ value: UInt32) -> IndicConjunct {", "        switch value {"]
    for source, target in [("Linker", ".linker"), ("Consonant", ".consonant"), ("Extend", ".extend")]:
        lines += case_lines(merge(incb.get(source, [])), target)
    lines += ["            default: return .none", "        }", "    }", ""]

    lines += boolean_function("isExtendedPictographic", emoji.get("Extended_Pictographic", [])) + [""]
    lines += boolean_function("isEmoji", emoji.get("Emoji", [])) + [""]
    lines += boolean_function("isWide", eaw.get("W", []) + eaw.get("F", [])) + [""]
    lines += boolean_function("isZeroWidth", zero_width) + [""]
    lines += boolean_function("isCombining", combining) + [""]
    lines += boolean_function("isVariationSelector", props.get("Variation_Selector", []))
    lines += ["}", ""]
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ucd-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    arguments.output.write_text(generate(arguments.ucd_dir), encoding="utf-8")


if __name__ == "__main__":
    main()
