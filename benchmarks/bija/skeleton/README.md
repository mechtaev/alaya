# Bija — implement the language

`SPEC.md` is the complete, normative definition of Bija, a small imperative language. This
repository has its build, its command line, and its test harness; the compiler itself is
missing. Your task is to write it.

```sh
uv run pytest          # the acceptance suite — currently all failing
uv run bija run p.bj   # currently: "bija: not implemented yet"
```

## What has to work

`bija run FILE` compiles a Bija program and runs it. `bija build FILE -o OUT.py` writes
**standalone** Python: running `python OUT.py` must produce exactly the same output, with no
import of this package. Exit codes are `0` for success, `1` for a runtime error (reported as
`error: MESSAGE` on standard error), and `2` for a compile-time error (reported as
`FILE:LINE:COLUMN: error: MESSAGE`).

Only `src/bija/` is yours to change. The harness in `tests/` and the contract above are fixed,
and `SPEC.md` is the authority on every question about behaviour — including the exact wording
of a diagnostic, which the specification constrains only where it says so.

## The suite

`tests/programs/` holds acceptance tests: whole Bija programs beside the exact standard output
they must produce. A `NAME.err` file means the program must fail with that message on standard
error; a `NAME.status` file overrides the expected exit code.

The twelve programs here are a sample, one from each area of the specification. **Grading uses a
much larger suite of the same shape** — a couple of hundred programs covering the lexical rules,
values and rendering, every operator and its precedence, control flow, scoping, generations,
deeds, `attempt`/`wither`, `ripen`, all nine builtins, and every error the specification calls
for. Passing the twelve is a start, not a finish: write to `SPEC.md`, not to the sample.

Three parts of the language have no counterpart in most languages, and are where a
conventionally-shaped implementation goes wrong:

* a variable is a stack of generations that `@` reads back into, and `depth` counts (§4.1);
* `attempt` rolls the storehouse back when the block withers, including from inside a deed
  called by it (§6.8);
* `ripen when` defers a block until a checkpoint at which its condition holds, with a scan
  order that is specified exactly (§6.9).

## Environment

No runtime dependencies; `pytest` is the only development dependency. The project targets
`ghcr.io/astral-sh/uv:alpine3.23`:

```sh
docker run --rm -v "$PWD:/project" -w /project \
  -e UV_PROJECT_ENVIRONMENT=/tmp/venv -e UV_LINK_MODE=copy \
  ghcr.io/astral-sh/uv:alpine3.23 uv run pytest
```
