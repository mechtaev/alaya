"""The `bija` command: run a program, or build Python from it."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from . import runtime
from .compiler import compile_source
from .lexer import BijaSyntaxError


def _compile_file(path: Path, embed: bool = True) -> str:
    source = path.read_text(encoding="utf-8")
    try:
        return compile_source(source, embed=embed)
    except BijaSyntaxError as error:
        sys.stderr.write(error.report(str(path)) + "\n")
        raise SystemExit(2)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="bija", description="the Bija compiler")
    commands = parser.add_subparsers(dest="command", required=True)

    run = commands.add_parser("run", help="compile a program and run it")
    run.add_argument("file", type=Path)

    build = commands.add_parser("build", help="compile a program to Python")
    build.add_argument("file", type=Path)
    build.add_argument("-o", "--output", type=Path, help="write here instead of stdout")

    arguments = parser.parse_args(argv)

    if arguments.command == "build":
        generated = _compile_file(arguments.file)
        if arguments.output is None:
            sys.stdout.write(generated)
        else:
            arguments.output.write_text(generated, encoding="utf-8")
        return 0

    # Running uses the runtime module rather than an inlined copy of it, so a program runs
    # against exactly the code the test suite measures. `build` inlines it instead.
    generated = _compile_file(arguments.file, embed=False)
    code = compile(generated, f"<{arguments.file}>", "exec")
    namespace = {name: getattr(runtime, name) for name in dir(runtime)}
    namespace["__name__"] = "__bija__"
    try:
        exec(code, namespace)  # noqa: S102 - running the program is the point
    except SystemExit as exit_request:
        return int(exit_request.code or 0)
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
