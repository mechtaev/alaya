"""Runs every acceptance program in-process, so `coverage` can see the compiler working.

`coverage run -m pytest` would measure almost nothing here: the suite runs each program in a
subprocess, which is the point — it checks the real command line and the standalone Python that
`bija build` writes. This driver takes the same programs through the same entry point inside
one process, purely so the numbers are visible.

    uv run coverage erase
    uv run coverage run scripts/coverage.py
    uv run coverage report
"""

from __future__ import annotations

import contextlib
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from bija.cli import main  # noqa: E402


def drive(arguments: list[str]) -> None:
    """Runs the command line, swallowing the program's output and its exit status."""
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            main(arguments)
    except SystemExit:
        pass
    except RecursionError:  # a program that recurses past the interpreter's limit
        pass


def run() -> int:
    programs = sorted((ROOT / "tests" / "programs").rglob("*.bj"))
    built = ROOT / "build" / "coverage-output.py"
    built.parent.mkdir(exist_ok=True)
    for program in programs:
        drive(["run", str(program)])
        drive(["build", str(program), "-o", str(built)])
    drive(["build", str(programs[0])])  # writing to standard output
    print(f"drove {len(programs)} programs")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
