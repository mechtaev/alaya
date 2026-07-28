# Alaya

A Lean 4 library for typed chat models, and two executables built on it:

- **`alaya`** — a port of [mini-SWE-agent](https://github.com/SWE-agent/mini-swe-agent) driving a
  content-addressed *trajectory tree*, so agent runs can be branched, replayed, and inspected.
- **`benchmark`** — a throughput comparison across providers and models.

The library underneath gives every model the same interface (`Alaya.Model`) and layers behaviour
on top of it: retry with backoff, sequential or concurrent batching, a persistent response cache
keyed by request and draw index, structured output, and a git-style content-addressed store
(`Alaya.Cas`) for filesystem snapshots.

## Building

```sh
lake build              # the alaya executable
lake build benchmark    # the benchmark executable
lake exe tests          # the test suite; pass a substring to run a subset
```

Binaries land in `.lake/build/bin/`.

## Providers and model specs

Both executables name a model with a `PROVIDER:NAME` spec; the name may itself contain colons,
so only the first one splits.

| Provider  | Default endpoint                | API key variable  |
| --------- | ------------------------------- | ----------------- |
| `yunwu`   | `https://yunwu.ai/v1`           | `YUNWU_API_KEY`   |
| `closeai` | `https://api.openai-proxy.org/v1` | `CLOSEAI_API_KEY` |
| `xmcp`    | `https://llm.xmcp.ltd`          | `XMCP_API_KEY`    |
| `dgx`     | `http://10.42.0.1:8000/v1`      | `DGX_API_KEY`     |

All four speak the OpenAI chat-completions protocol. A missing or empty key is a configuration
error, except for `dgx`, where the key defaults to `EMPTY` — the vLLM convention for a local
server that needs no credential.

```sh
export YUNWU_API_KEY=...
alaya resume abc123 --model yunwu:gpt-5.6-luna
```

### Addressing a DGX Spark

`dgx` is a self-hosted OpenAI-compatible server (vLLM, SGLang, llama.cpp, …) on a DGX Spark. Its
address comes from, in order of precedence:

1. `--url` and `--port` on the command line,
2. the `DGX_BASE_URL` environment variable,
3. the built-in default, `http://10.42.0.1:8000/v1`.

`--url` accepts anything from a bare host to a full URL, and fills in whatever is missing
(`http` scheme, port `8000`, path `/v1`):

```sh
benchmark --model dgx:gpt-oss-120b --url http://192.168.1.5:9000/v1
benchmark --model dgx:gpt-oss-120b --url spark.local:9000
benchmark --model dgx:gpt-oss-120b --url spark.local --port 9000
benchmark --model dgx:gpt-oss-120b --port 9000          # default host, other port
```

`--port` wins over a port inside `--url`. Passing either one turns off the `DGX_BASE_URL`
fallback, so an explicit flag is never silently overridden by the environment.

## `alaya`

An agent run is a **tree of immutable states**. Each state records its parent, the messages that
turn appended to the dialogue, and a snapshot of the whole working directory — all content
addressed, so a state *is* its hash. Nothing is ever rewritten: every command that grows the tree
adds a child. Hashes are what you pass to commands; copy them from `alaya tree` and abbreviate
them to any unambiguous prefix.

```
alaya root TASK PROJECT [--image IMAGE]          create a root state from a project directory
alaya root TASK --image IMAGE --path PATH        …or from a path inside the image
alaya resume HASH --model P:M                    grow one continuation to completion
alaya step   HASH --model P:M                    advance exactly one model turn
alaya eval   HASH --command C [--test-patch F]   run tests against a state, recording a verdict
alaya commit HASH DIR [-m NOTE]                  record a hand-edited workspace as a child
alaya checkout HASH DIR                          materialize a state's workspace into DIR
alaya tree                                       show the whole forest
alaya html [FILE]                                write the whole forest as one HTML page
alaya show HASH                                  show a state's metadata and dialogue
alaya diff A B                                   workspace changes between two states
alaya rm HASH                                    delete a subtree and reclaim blobs
```

### The data directory

`--data D` (default `.alaya`) is the only directory flag, and it holds everything:

| Path      | Contents                                                                      |
| --------- | ----------------------------------------------------------------------------- |
| `D/store` | the content-addressed store: every state, dialogue, and workspace snapshot     |
| `D/cache` | cached model responses                                                        |
| `D/work`  | the directory the agent runs its commands in                                  |

So a run is one directory you can archive or delete as a unit. It must sit outside `PROJECT`,
since the store cannot live inside the tree it snapshots.

`D/work` is the one part that holds nothing durable, and it is not configurable. Every turn
begins by **wiping it** and re-materializing the parent state's snapshot into it, so anything
there that was not captured into the store is lost — which is exactly why no path you name can
end up as the work directory. Only `resume` and `step` touch it. Concurrent runs need separate
`--data` directories.

### Running in a container

`alaya root TASK PROJECT --image IMAGE` pins the trajectory to a container image; every command
of every continuation then runs in it. `D/work` is bind-mounted at `/workspace`, so the snapshot
that defines a state is still a host directory and the tree, `diff`, `checkout`, and branching
are unchanged.

| Flag                | Meaning                                                            |
| ------------------- | ------------------------------------------------------------------ |
| `--image IMAGE`     | image to run in; only on `root` (and see the pinning rule below)    |
| `--container-user U`| `uid:gid` to run as; defaults to your own on Linux, the image's on macOS |
| `--network N`       | passed to `docker run --network`; e.g. `none` to cut off the network |

**The image is a property of the trajectory, not of an invocation.** It is resolved to a digest
at `root` time (`alpine@sha256:…`, or the image id for a locally built one) and recorded in
every state, because the root prompt tells the model the `uname` of the machine it is on — read
from the image, not from your laptop. `resume` and `step` therefore need no flags: they use the
recorded image, and refuse a `--image` that resolves to anything else. `alaya show` prints it.

One container is started per run and each command goes through `docker exec`, so an install in
one command is visible to the next, as in mini. What that costs: **only `/workspace` is part of
a state.** Packages installed into the image's filesystem live as long as the run and are gone
when a branch is resumed later. Anything that must survive branching belongs in the workspace or
in the image.

**Seeding from the image.** Task images usually carry the project already, so there may be
nothing on the host to point `root` at. `--path PATH` copies that path out of the image instead
of taking a `PROJECT` directory:

```sh
root=$(alaya root "fix the failing test" --image swebench/task:latest --path /testbed)
```

The copy uses a container that is created but never started, so nothing in the image runs while
the trajectory is being seeded.

Timeouts are enforced inside the container with `timeout(1)` when the image has one, so a
runaway command's whole process group dies as it does locally; a host-side deadline kills the
container as a backstop, and the next command starts a fresh one. Docker's own failures (a
missing image, a dead daemon) become exception observations rather than crashing the run, and
the container is removed when the run ends.

### Evaluating a state

`alaya eval HASH --command C` checks out a state's workspace, overlays a set of tests the agent
never saw, runs the command there, and records the verdict as a **leaf child** of the state:

```sh
alaya eval 4f2c --command "pytest -x tests/test_foo.py" --test-patch ./test_patch.diff
# 7b19d4c2ff01  fail 1  (48210 ms)
```

| Flag                     | Default | Meaning                                              |
| ------------------------ | ------- | ---------------------------------------------------- |
| `--command C`            | —       | the test command (required)                          |
| `--tests DIR`            | —       | overlay a host directory onto the workspace          |
| `--test-patch FILE`      | —       | apply a unified diff (SWE-bench's `test_patch`)      |
| `--tests-from-image PATH`| —       | copy the tests out of the trajectory's image         |
| `--timeout S`            | `900`   | how long the test command may run                    |
| `--force`                | off     | re-run instead of returning the existing verdict     |

The evaluation is a node like any other, so the tree shows it and `checkout` gives you the exact
tree that was tested:

```
adbac197aea8  root  fix the failing test
  4f2c8b1e0a33  bash  pytest tests/test_foo.py rc=1
    7b19d4c2ff01  eval  [fail 1]  pytest -x tests/test_foo.py
```

Three properties this buys, all of which matter if the number at the end is meant to mean
something:

- **The tests never reach the agent.** They are in the eval node's workspace, never in the state
  it was run against, and `resume`, `step`, and `commit` refuse an evaluation node. A benchmark
  run cannot be contaminated by its own measurement.
- **The overlay wins.** Overlaid files replace whatever the agent left. With `--test-patch`, the
  files the patch touches are first restored to the trajectory's **base commit** (recorded at
  `root`, from `--base-commit` or read from the checkout's `HEAD`) — or deleted, if they did not
  exist there — so an agent that weakened or removed a test does not get to decide its own
  verdict.
- **Everything is addressed.** The overlay is stored by content, so one test set shared across
  hundreds of task instances is stored once, and `alaya diff 4f2c 7b19` is exactly what the
  harness added. Re-evaluating the same state, command, and overlay returns the existing node
  rather than piling up duplicates.

Note that a verdict is a different axis from a run's `Outcome`: a submitted run can fail its
tests, and a run that hit the step limit can pass them.

### Reading a run back

`alaya html` writes the entire data directory to a single self-contained page — no network, no
assets — defaulting to `D/report.html`:

```sh
alaya html && open .alaya/report.html
```

The tree is on the left and the selected state fills the rest: its metadata, the messages that
turn appended (assistant text, the commands it ran, and each observation with its return code),
the workspace changes it made as a line diff, and any verdict recorded against it.

Each row carries a glyph for what the state is — a seed for a root, a prompt for an agent turn,
a warning for a format error, a diamond for a hand-made commit, and a tick or a cross for a
verdict — so the shape of a run reads without any labels to parse.

**A line of turns grows straight down.** Indentation means a fork, and only a fork: a state with
one child keeps it at the same level, while a state with two or more puts every one of them a
level deeper behind a rail. A hundred-turn run is therefore one column rather than a staircase
off the right edge, and a line on the left always marks a set of siblings. The state that starts
each branch is marked twice — an elbow from the rail into its row, and a `1/2` badge saying
which way it is — so a sibling that appears fifty rows below its fork cannot be misread as one
more turn of the branch above it. Every node collapses, showing how many states it hides; subtrees are built
the first time they are opened, so the page opens at the same speed whatever the forest weighs —
a 5 000-state forest renders its first 300 rows in milliseconds and expands in full on request.
There is a find box (enter for the next match, shift-enter for the previous), expand and
collapse buttons, and arrow keys to walk the visible rows.

Long output is clipped with a toggle, and files are collapsed until opened. Text is carried into the diff
only when it is small and textual and not under a generated directory such as `.venv/`, so a
report stays a readable size; those paths are still listed, just not diffed.

### Sampling, caching, and branching

Responses are cached in `D/cache`, keyed by the request *and a draw index*. Growing a
continuation from a state with `n` children asks for draw `n`, past every recorded draw — so
existing branches replay from cache deterministically, a new continuation is always a fresh
sibling, and an interrupted run resumes without re-billing the turns it already made.

`--temperature T` (default `0.0`) sets the sampling temperature.

### An example

```sh
export DGX_API_KEY=EMPTY

# Snapshot a project as the root of a new trajectory, pinned to an image to run in.
root=$(alaya root "make the test suite pass" ./myproject --image python:3.12-slim)

# Run to completion, printing each new state as it appears. The image comes from the state.
alaya resume "$root" --model dgx:gpt-oss-120b --url spark.local:9000

alaya tree                       # the forest, with each state's kind and outcome
alaya show 4f2c                  # metadata and dialogue of one state
alaya diff "$root" 4f2c          # what the agent changed
alaya checkout 4f2c ./inspect    # get that state's files to look at

# Fix something by hand, record it as a child, and let the agent continue from there.
alaya commit 4f2c ./inspect -m "fixed the flaky fixture"
alaya resume <new-hash> --model dgx:gpt-oss-120b

alaya rm 4f2c                    # drop a subtree and garbage-collect its blobs
```

A SWE-bench-shaped run, start to finish:

```sh
root=$(alaya root "$PROBLEM_STATEMENT" --image "$TASK_IMAGE" --path /testbed)
final=$(alaya resume "$root" --model dgx:gpt-oss-120b | tail -1 | cut -d' ' -f1)
alaya eval "$final" --test-patch ./test_patch.diff \
  --command "python -m pytest -rA $FAIL_TO_PASS $PASS_TO_PASS"
```

Every command takes `--data`. `root` additionally takes `--image` (with `--container-user` and
`--network`) and `--base-commit`; `resume` and `step` take `--model`, `--temperature`, and the
DGX flags `--url`/`--port`; `eval` takes the flags in its table above.

## `benchmark`

Measures decode throughput and compares models — across providers, or across model names on one
provider.

```
usage: benchmark --model PROVIDER:NAME [--model PROVIDER:NAME ...] [--count N]
                 [--temperature T] [--concurrent [N]] [--prompt TEXT | --prompt-file F]
                 [--url U] [--port N]
```

| Flag              | Default       | Meaning                                                     |
| ----------------- | ------------- | ----------------------------------------------------------- |
| `--model P:N`     | *(required)*  | a model to measure; repeat it to compare several             |
| `--count N`       | `8`           | requests per phase                                           |
| `--temperature T` | `0.7`         | sampling temperature                                         |
| `--concurrent [N]`| off           | also run a concurrent phase; `N` caps requests in flight     |
| `--prompt TEXT`   | built-in      | the prompt to send                                           |
| `--prompt-file F` | built-in      | read the prompt from a file instead                          |
| `--url U`, `--port N` | —         | where the `dgx` provider's server listens                    |

Each model runs a **sequential** phase — `--count` requests one after another, measuring
single-stream decode speed — and, with `--concurrent`, a **concurrent** phase that puts all of
them in flight at once (bounded by `N` if given) to measure aggregate throughput under load. Bare
`--concurrent` leaves it unbounded.

The default prompt is a code-generation task sized to produce a few hundred output tokens.
Token counts come from the provider's reported usage; when a provider omits it, the count is
estimated from response length and marked with `*`.

A model that cannot be reached is reported and skipped, so one bad spec or unreachable server
does not lose the other models' measurements. When more than one measurement succeeds, a summary
table is printed, fastest first.

```sh
benchmark --model dgx:gpt-oss-120b --model xmcp:claude-sonnet-4-5 \
          --count 16 --concurrent 8 --url spark.local:9000
```

```
# count=16 temperature=0.7 concurrent=8

## dgx:gpt-oss-120b
sequential    16 req     4821 tok    39102 ms     123 tok/s
concurrent    16 req     4790 tok     9944 ms     481 tok/s

## xmcp:claude-sonnet-4-5
sequential    16 req     5210 tok    31887 ms     163 tok/s
concurrent    16 req     5188 tok    12203 ms     425 tok/s

model                   phase          tok/s      tok       ms   req
--------------------------------------------------------------------
dgx:gpt-oss-120b        concurrent       481     4790     9944    16
xmcp:claude-sonnet-4-5  concurrent       425     5188    12203    16
xmcp:claude-sonnet-4-5  sequential       163     5210    31887    16
dgx:gpt-oss-120b        sequential       123     4821    39102    16
```

## Command-line conventions

Both executables share one parser (`Alaya.Cli`): positionals and `--flag value` pairs may be
interleaved in any order, and `alaya` also accepts `-m` for `--note`. A flag that is repeated
keeps every value — that is how `benchmark` takes several `--model` specs — and for flags read as
a single value, the last occurrence wins. A flag that is last on the line or followed by another
flag is a switch with no value, which is why both `--concurrent` and `--concurrent 8` work. The
one consequence to know: a flag *value* may not begin with `--`.
