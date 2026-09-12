#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Grade a Bija attempt against the reference acceptance suite.

usage: grade.py CHECKOUT OUT

CHECKOUT is a checkout of the attempt; its `tests/` is replaced by the reference's 232 programs,
and the suite is run in the benchmark's container image. OUT receives `pytest.txt` (the suite's
output), `junit.xml` (per-test results), and `verdict.json`:

    {"passed": false,
     "score": {"passed": 155, "total": 232},
     "standalone": {"passed": 150, "total": 232},
     "areas": {"attempt": {"passed": 14, "total": 16}, ...}}

`score` counts `test_program`: one check per program, run through the command line.
`standalone` counts `test_generated_python_is_standalone` for the same programs. `passed` is
true when every check of both kinds passed. The exit status is 0 when passed, 1 otherwise.

Run as an alaya grader from the repository root:

    alaya eval HASH --grader 'example/bija/grade.py {checkout} {out}' --timeout 1800
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

IMAGE = "ghcr.io/astral-sh/uv:python3.12-alpine3.23"
HERE = Path(__file__).resolve().parent
REFERENCE_TESTS = HERE / "reference" / "tests"


def run_suite(checkout: Path, out: Path) -> int:
    """Runs pytest in the container; the results go to OUT. Returns pytest's exit status."""
    tests = checkout / "tests"
    if tests.exists():
        shutil.rmtree(tests)
    shutil.copytree(REFERENCE_TESTS, tests, ignore=shutil.ignore_patterns("__pycache__"))
    command = [
        "docker", "run", "--rm",
        "-v", f"{checkout}:/workspace", "-v", f"{out}:/out", "-w", "/workspace",
        # A fresh environment outside the checkout, so the attempt's own .venv is neither
        # trusted nor modified; the cache volume keeps the second run from downloading again.
        "-e", "UV_PROJECT_ENVIRONMENT=/tmp/venv", "-e", "UV_LINK_MODE=copy",
        "-v", "bija-grader-uv-cache:/root/.cache/uv",
        IMAGE, "uv", "run", "pytest", "-q", "--tb=no", "-p", "no:cacheprovider",
        "--junitxml=/out/junit.xml",
    ]
    with (out / "pytest.txt").open("w", encoding="utf-8") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    return result.returncode


def count(cases: list[ET.Element]) -> dict[str, int]:
    passed = sum(1 for case in cases if case.find("failure") is None and case.find("error") is None)
    return {"passed": passed, "total": len(cases)}


def verdict(junit: Path) -> dict:
    cases = list(ET.parse(junit).getroot().iter("testcase"))
    programs = [c for c in cases if c.get("name", "").startswith("test_program[")]
    standalone = [c for c in cases if c.get("name", "").startswith("test_generated_python_is_standalone[")]
    areas: dict[str, list[ET.Element]] = {}
    for case in programs:
        # test_program[attempt/nested_wither] -> attempt
        area = case.get("name", "").split("[", 1)[1].split("/", 1)[0]
        areas.setdefault(area, []).append(case)
    score = count(programs)
    alone = count(standalone)
    return {
        "passed": score["passed"] == score["total"] and alone["passed"] == alone["total"],
        "score": score,
        "standalone": alone,
        "areas": {area: count(group) for area, group in sorted(areas.items())},
    }


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write(__doc__)
        return 2
    checkout, out = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    status = run_suite(checkout, out)
    junit = out / "junit.xml"
    if not junit.exists():
        sys.stdout.write((out / "pytest.txt").read_text(encoding="utf-8", errors="replace"))
        sys.stderr.write(f"grade.py: the suite did not run (pytest exit {status})\n")
        return 1
    result = verdict(junit)
    (out / "verdict.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    areas = ", ".join(f"{a} {c['passed']}/{c['total']}" for a, c in result["areas"].items())
    sys.stdout.write(
        f"programs {result['score']['passed']}/{result['score']['total']}, "
        f"standalone {result['standalone']['passed']}/{result['standalone']['total']}\n{areas}\n")
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
