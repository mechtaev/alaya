# Bija — a long-horizon task for the agent

Bija is a small imperative language invented for this benchmark: ordinary in most respects, and
deliberately unusual in three that cannot be guessed from familiarity with other languages. The
task is to implement its compiler from a written specification.

| Directory    | What it is                                                                    |
| ------------ | ----------------------------------------------------------------------------- |
| `skeleton/`  | the starting point: the whole specification, the harness, and a `bija` command that reports "not implemented yet" |
| `reference/` | a complete implementation with 232 acceptance programs, 100% statement coverage |

## Why this task

* **It is long.** A correct implementation is a lexer, a parser, static checks, a code
  generator and a runtime — roughly a thousand statements of Python, decomposable into pieces
  that are nonetheless coupled through the specification.
* **It cannot be faked from familiarity.** A variable is a stack of generations that `@` reads
  back into; `attempt` rolls the storehouse back when a block withers, including from inside a
  called deed; `ripen when` defers a block until a checkpoint at which its condition holds.
  An implementation shaped like a conventional language passes the arithmetic and fails these.
* **Progress is a number at every moment.** The suite is whole programs against exact output,
  so a partial implementation scores a fraction rather than an opinion.
* **The grader is bigger than the sample.** The skeleton ships twelve programs, one per area;
  the reference has 232 of the same shape. Running the reference's suite against an agent's
  implementation measures generalisation from the specification rather than fitting to the
  visible tests.

## Running it

Both directories are self-contained uv projects with no runtime dependencies, targeting
`ghcr.io/astral-sh/uv:alpine3.23`:

```sh
cd reference && uv run pytest        # 464 tests, all passing
cd skeleton  && uv run pytest        # 24 tests, all failing, until the work is done
```

To grade an attempt, run the reference's suite against the attempt's `src/bija/`:

```sh
cp -r <attempt>/src/bija reference-check/src/     # reference tests, candidate implementation
cd reference-check && uv run pytest -q
```

## Driving it with alaya

The skeleton is a project directory, so it seeds a trajectory directly:

```sh
root=$(alaya root "$(cat benchmarks/bija/TASK.txt)" benchmarks/bija/skeleton \
  --image ghcr.io/astral-sh/uv:python3.12-alpine3.23)

alaya resume "$root" --model dgx:gpt-oss-120b
```

`TASK.txt` is the task statement, kept in the repository so every run is given the same one. It
is worded deliberately: an earlier version asked for "the acceptance suite in tests/ to pass",
which makes the twelve visible programs the target rather than the specification, and an agent
that satisfies them has done a twelfth of the work while believing it is finished.

The image carries `uv`, so the agent can run the suite itself between turns; every command it
runs is snapshotted, so a branch can be taken from any point where it went wrong. To measure
the result against the full suite rather than the visible twelve, evaluate the final state with
the reference's tests as the overlay:

```sh
mkdir -p /tmp/bija-overlay && cp -R benchmarks/bija/reference/tests /tmp/bija-overlay/
alaya eval <final-hash> --tests /tmp/bija-overlay \
  --command "uv run pytest -q --tb=no -p no:cacheprovider" --timeout 1800
```

`--tests` copies the *contents* of the directory over the workspace, so the overlay has to
contain a `tests/` directory rather than being one. Give `--command` a single command, not a
pipeline: a shell pipeline reports the exit status of its last stage, so `… | tail -5` would
record a pass no matter what the tests did.

That is exactly the case `alaya eval` exists for: the hidden tests reach the workspace, the
verdict is recorded as a leaf, and no state the agent could continue from ever contains them.
