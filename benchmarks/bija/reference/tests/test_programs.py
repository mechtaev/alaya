"""The acceptance suite: every test is a whole Bija program, checked against its output.

For each `NAME.bj` under `tests/programs/`:

* `NAME.out`    — the exact expected standard output (required).
* `NAME.err`    — the exact expected standard error, when the program is meant to fail.
* `NAME.status` — the expected exit code; defaults to 0, or 1 when `NAME.err` is present.

Programs are run through the real command line, from their own directory, so a diagnostic
naming the source file is stable. Each program is also compiled to standalone Python and run
under a bare interpreter, which is what `bija build` promises.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

PROGRAMS = Path(__file__).parent / "programs"
CASES = sorted(PROGRAMS.rglob("*.bj"))
IDS = [str(case.relative_to(PROGRAMS).with_suffix("")) for case in CASES]

assert CASES, "no acceptance programs found"


def _expected(case: Path) -> tuple[str, str, int]:
    out = case.with_suffix(".out")
    err = case.with_suffix(".err")
    status = case.with_suffix(".status")
    expected_out = out.read_text(encoding="utf-8") if out.exists() else ""
    expected_err = err.read_text(encoding="utf-8") if err.exists() else ""
    if status.exists():
        expected_status = int(status.read_text(encoding="utf-8").strip())
    else:
        expected_status = 1 if expected_err else 0
    return expected_out, expected_err, expected_status


def _run(arguments: list[str], cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-m", "bija.cli", *arguments],
        cwd=cwd, capture_output=True, text=True, timeout=60,
    )


@pytest.mark.parametrize("case", CASES, ids=IDS)
def test_program(case: Path) -> None:
    expected_out, expected_err, expected_status = _expected(case)
    result = _run(["run", case.name], cwd=case.parent)
    assert result.stdout == expected_out, f"stdout mismatch\n{result.stdout!r}"
    assert result.stderr == expected_err, f"stderr mismatch\n{result.stderr!r}"
    assert result.returncode == expected_status


@pytest.mark.parametrize("case", CASES, ids=IDS)
def test_generated_python_is_standalone(case: Path, tmp_path: Path) -> None:
    """`bija build` output must behave identically under a bare interpreter."""
    expected_out, expected_err, expected_status = _expected(case)
    built = _run(["build", case.name, "-o", str(tmp_path / "out.py")], cwd=case.parent)
    if expected_status == 2:
        assert built.returncode == 2 and built.stderr == expected_err
        return
    assert built.returncode == 0, built.stderr
    result = subprocess.run(
        [sys.executable, str(tmp_path / "out.py")],
        cwd=case.parent, capture_output=True, text=True, timeout=60,
    )
    assert result.stdout == expected_out
    assert result.stderr == expected_err
    assert result.returncode == expected_status
