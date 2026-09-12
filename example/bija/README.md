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
`ghcr.io/astral-sh/uv:python3.12-alpine3.23`:

```sh
cd reference && uv run pytest        # 464 tests, all passing
cd skeleton  && uv run pytest        # 24 tests, all failing, until the work is done
```

## The grader

`grade.py CHECKOUT OUT` grades an attempt: it replaces the attempt's `tests/` with the
reference's 232 programs, runs the suite in the benchmark's image, and writes `verdict.json`
into `OUT` beside the suite's output and its JUnit report. The score counts programs that run
correctly through the command line (`test_program`); `standalone` counts the same programs
compiled with `bija build` and run under a bare interpreter; `areas` breaks the score down by
section of the specification. It needs `docker` and `uv` on the host.

```json
{"passed": false,
 "score": {"passed": 155, "total": 232},
 "standalone": {"passed": 150, "total": 232},
 "areas": {"attempt": {"passed": 14, "total": 16}, "builtins": {"passed": 22, "total": 22}, ...}}
```

## Driving it with alaya

The skeleton is a project directory, so it seeds a trajectory directly; `TASK.txt` is the task
statement, kept here so every run is given the same one. From the repository root:

```sh
root=$(alaya root "$(cat example/bija/TASK.txt)" example/bija/skeleton --agent mini-swe \
  --image ghcr.io/astral-sh/uv:python3.12-alpine3.23)

alaya resume "$root" --agent mini-swe --model dgx:gpt-oss-120b

alaya eval <final-hash> --grader 'example/bija/grade.py {checkout} {out}' --timeout 1800
# <hash>  fail 1 155/232  (61377 ms)
```

The image carries `uv` and Python, so the agent can run the sample suite itself between turns.
The agent never sees the reference programs: the grader copies them over a checkout that is
discarded afterwards, and the verdict is recorded as a leaf. `example/README.md` walks through
one such run, with a fork and an intervention, both branches graded.
