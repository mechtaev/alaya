# Bija

Bija (Sanskrit *bīja*, "seed") is a small imperative language, and this is its compiler: it
translates a `.bj` program to a standalone Python file.

The name comes from the seeds that Yogācāra Buddhism holds are deposited in the
*ālaya-vijñāna*, the storehouse consciousness — every act leaves an imprint, imprints
accumulate, and later conditions cause them to ripen. Bija takes that literally:

```
0 => sow total.
each n in range(1, 5):
  total + n => total.
end.

utter total.        ~~ 10
utter total@1.      ~~ 6   — the generation before the last
utter depth total.  ~~ 5   — one initial generation, four plantings

attempt:
  999 => total.
  wither.
end.

utter total.        ~~ 10  — the rollback undid the planting
```

* **A variable is a stack of generations, not a cell.** `x => y` plants a new generation;
  `y@2` reads the one from two plantings ago; `depth y` counts them.
* **A block can be undone.** `attempt: … wither. … end.` rolls the storehouse back to the
  state it had when the block began.
* **An effect can be deferred.** `ripen when c: … end.` registers a block that runs later, at
  the first point where `c` holds.

Everything else is ordinary: integers of arbitrary size, texts, flags, `void`, immutable
lists, `when`/`while`/`each`, and deeds (procedures) that see only their own parameters.

**[SPEC.md](SPEC.md) is the normative definition of the language.** It is precise enough to
implement against, and the acceptance suite tests against it rather than against this
implementation.

## Using it

```sh
uv run bija run examples/collatz.bj      # compile and run
uv run bija build examples/collatz.bj    # print the generated Python
uv run bija build p.bj -o p.py && python p.py   # the generated file is standalone
```

Exit codes are `0` for success, `1` for a runtime error (reported as `error: …` on stderr),
and `2` for a compile-time error (reported as `file:line:column: error: …`).

## Development

The project targets `ghcr.io/astral-sh/uv:alpine3.23` and has no runtime dependencies:

```sh
docker run --rm -v "$PWD:/project" -w /project \
  -e UV_PROJECT_ENVIRONMENT=/tmp/venv -e UV_LINK_MODE=copy \
  ghcr.io/astral-sh/uv:alpine3.23 uv run pytest
```

`UV_PROJECT_ENVIRONMENT` keeps the container's virtual environment out of the mounted tree, so
running the suite in the container does not invalidate the one on the host. `docker build .`
uses the same image if you would rather not mount anything.

Locally, `uv run pytest` does the same thing.

### Coverage

The suite runs each program in a subprocess, so `coverage run -m pytest` would measure almost
nothing. `scripts/coverage.py` takes the same programs through the same entry point in one
process:

```sh
uv run coverage erase && uv run coverage run scripts/coverage.py && uv run coverage report
```

The 232 acceptance programs cover 100% of the statements in `src/bija/`.

## The test suite

`tests/programs/` holds acceptance tests — whole Bija programs with their expected output,
never unit tests of the compiler's internals — grouped by the part of the specification they
exercise:

| Directory     |   n | Covers                                                     |
| ------------- | --: | ---------------------------------------------------------- |
| `lexical/`    |  11 | literals, comments, escapes, free-form layout               |
| `values/`     |  12 | rendering, equality, immutability                           |
| `operators/`  |  25 | arithmetic, comparison, logic, indexing, precedence         |
| `control/`    |  18 | `when`, `while`, `each`                                     |
| `seeds/`      |  18 | sowing, planting, scoping, generations, `depth`             |
| `deeds/`      |  15 | calls, recursion, parameter seeds, the parentless scope     |
| `attempt/`    |  16 | rollback, nesting, dynamic `wither` through deeds           |
| `ripen/`      |  19 | registration, checkpoints, ordering, cascades, interactions |
| `builtins/`   |  22 | the nine builtin deeds                                      |
| `errors/`     |  60 | every diagnosed compile-time and runtime error              |
| `programs/`   |  16 | larger programs: sorting, primes, a stack machine, a bank   |

Each test is a `NAME.bj` file beside a `NAME.out` file holding the exact expected standard
output. If a `NAME.err` file is present, the program is expected to fail with that message on
stderr; a `NAME.status` file overrides the expected exit code (`1` by default when `.err` is
present, `2` for compile-time errors).

Adding a test means adding those files; the runner discovers them.

## Using this as an agent task

The repository is built to be taken apart. `SPEC.md` defines the language precisely enough to
implement from scratch, and the suite tests against the specification rather than against this
implementation, so an agent can be asked to rebuild any part of it and be graded objectively:

```sh
rm -rf src/bija                     # "implement the language in SPEC.md"
rm src/bija/compiler.py             # "the parser and runtime are given; write the compiler"
git checkout HEAD~1 -- src/bija     # or roll back to any earlier state
```

Useful properties for a long-horizon task: the work is decomposable (lexer, parser, static
checks, code generation, runtime) but the pieces are coupled through the specification; progress
is measurable at any moment as a fraction of 232 programs passing; and the three unusual
features mean a plausible-looking implementation copied from another language will fail on the
`seeds/`, `attempt/` and `ripen/` groups specifically.

Running one group at a time keeps the feedback loop tight:

```sh
uv run pytest -k "seeds/"
uv run pytest -k "ripen/ and not standalone"
```
