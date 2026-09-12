"""The `bija` command: run a program, or build Python from it.

Nothing here is implemented yet. SPEC.md defines the language; `tests/programs/` holds the
acceptance suite that decides whether an implementation is correct.

The contract the tests rely on:

* `bija run FILE` compiles FILE and runs it, writing the program's output to standard output.
* `bija build FILE [-o OUT]` writes standalone Python — a file that produces exactly the same
  output under a bare interpreter, with no import of this package.
* Exit codes are 0 for success, 1 for a runtime error (reported as `error: MESSAGE` on standard
  error), and 2 for a compile-time error (reported as `FILE:LINE:COLUMN: error: MESSAGE`).
"""

from __future__ import annotations

import sys


def main(argv: list[str] | None = None) -> int:
    sys.stderr.write("bija: not implemented yet — see SPEC.md\n")
    return 70


if __name__ == "__main__":
    raise SystemExit(main())
