# Experiments

## 1. mini-SWE-agent + `yunwu:gpt-5.4-mini` on the Bija benchmark

**Question.** Can the ported agent, driven by a small model, implement a language from a
specification it has never seen? The Bija benchmark (`benchmarks/bija/`) is built for this: the
skeleton ships the whole specification, the harness, and twelve sample programs, while grading
uses the reference's 232.

**Setup.** `alaya` at `2b2a0bf`, agent image `ghcr.io/astral-sh/uv:alpine3.23`
(`sha256:d7c59d83…`), model `yunwu:gpt-5.4-mini` at temperature 0, unlimited steps, 30 s per
command. `YUNWU_API_KEY` must be set.

### Commands

```sh
lake build alaya && export PATH="$PWD/.lake/build/bin:$PATH"

# Check the model answers at all before spending a run on it.
benchmark --model yunwu:gpt-5.4-mini --count 1 --prompt "Reply with exactly: ok"

# Seed a trajectory from the skeleton, pinned to the image the agent will run in.
root=$(alaya root "Implement the Bija compiler described in SPEC.md so that the acceptance \
suite in tests/ passes. Only files under src/bija/ may be changed. Run 'uv run pytest' to \
check your work." benchmarks/bija/skeleton --image ghcr.io/astral-sh/uv:alpine3.23)

# Run to completion. Each line is a new state; the last is the outcome.
alaya resume "$root" --model yunwu:gpt-5.4-mini

# Grade against the 232-program reference suite the agent never saw.
mkdir -p /tmp/bija-overlay && cp -R benchmarks/bija/reference/tests /tmp/bija-overlay/
alaya eval 86844e771e69 --tests /tmp/bija-overlay \
  --command "uv run pytest -q --tb=no -p no:cacheprovider" --timeout 1800
```

Inspecting the run afterwards:

```sh
alaya tree
alaya show 86844e771e69                       # dialogue and metadata of the final state
alaya diff 6835b74b3a51 86844e771e69          # what the agent changed
alaya checkout 86844e771e69 /tmp/bija-attempt # its workspace, to run anything by hand
```

### Result

The run ended after **19 turns** with `Submitted` — the agent's own claim of completion.
Root `6835b74b3a51`, final state `86844e771e69`, verdict node `4950a817444d`: **fail 1** in
49.3 s.

| Suite                       | Passed  |
| --------------------------- | ------- |
| `test_program` (via the CLI)| 85/232  |
| `test_generated_python_is_standalone` | 3/232 |
| Total                       | 88/464  |

By area, for the 232 `test_program` cases:

| Area        | Passed | Area        | Passed |
| ----------- | -----: | ----------- | -----: |
| `operators` |  22/25 | `values`    |   9/12 |
| `builtins`  |  14/22 | `attempt`   |   2/16 |
| `deeds`     |  12/15 | `ripen`     |   1/19 |
| `control`   |  11/18 | `seeds`     |   1/18 |
| `lexical`   |   9/11 | `errors`    |   4/60 |
| `programs`  |   0/16 |             |        |

**The benchmark separates what it was built to separate.** The conventional half of the
language is largely there — operators 22/25, deeds 12/15, lexical 9/11 — while the three
features that have no counterpart elsewhere are essentially absent: generations 1/18, rollback
2/16, deferred ripening 1/19. An implementation shaped by familiarity gets the arithmetic and
misses the language.

Two other things the numbers show. `errors` at 4/60 is diagnostics: the specification fixes the
exact text of a message, and matching it is work the agent did not do. `standalone` at 3/232 is
a requirement it read and then ignored — its `bija build` writes a file that imports
`bija.cli`, so the output is not standalone, and the three passes are compile-error cases where
`build` is only required to fail.

**What the agent did.** One 523-line `src/bija/cli.py` holding a hand-written lexer, parser and
**tree-walking interpreter** — not a compiler to Python, which is what the contract asks for and
what the standalone tests measure. The last five turns were spent trying to patch a stale string
inside its own `build_file`, twice with a `python3` that does not exist in the image (`rc=127`),
once producing a format error; it then submitted while its own `uv run pytest` was still failing.

### Notes on running it

* **Give `--command` a single command.** My first evaluation used
  `--command "uv run pytest -q 2>&1 | tail -5"` and was recorded as **pass**: a shell pipeline
  exits with the status of its last stage, so the verdict measured `tail`. The result was a
  correctly-recorded verdict about the wrong thing. `benchmarks/bija/README.md` now says so.
* **`--tests` takes a directory whose *contents* are copied over the workspace**, so it must
  contain `tests/`, not be it.
* **The recorded output is truncated at 20 000 characters**, which cut pytest's summary line out
  of the middle of a long failure list. For counts, check the state out and run the suite
  directly, as above.
* **`.venv/` and `__pycache__/` end up in the snapshot**, since a capture takes the whole work
  directory. Correct, and heavy: the store grows by an environment per turn that touches it.
  Worth an ignore list in `Cas.CaptureConfig` before running this at scale.

### 1a. Forking, and the bug it exposed

Forking the run at `ff730e730bea`, the last turn before the agent started patching its own
`build_file`:

```sh
alaya resume ff730e730bea --model yunwu:gpt-5.4-mini --temperature 0.7
```

Temperature matters here: the run was sampled at 0, so a fork at 0 retraces the same path and
wastes the turns. The branch lasted two turns — it tried to run every sample program in one
Python process instead of calling pytest, hit the 30-second command timeout while `uv` was still
downloading CPython into a fresh container, and submitted on the timeout.

**Its first turn recorded 275 of the reference test files into its workspace.** Not the agent's
doing: `Store.materialize` is incremental and trusts the store's record of what a directory
holds, and nothing updated that record after the writes that a run and an evaluation make to the
work directory. The next checkout therefore applied a diff from a stale record and left
everything those writes had added — the abandoned branch's files for any fork, and, after an
evaluation, the hidden tests. That broke the property `eval` exists to guarantee.

`checkoutInto` now materializes with `verify := true`, so the directory is re-captured and a
mismatch forces a full write. Two tests cover it (`mini.session`), and forking the same state
again records a workspace identical to its parent's:

| fork of `ff730e730bea` | paths changed vs parent | of which `tests/` |
| ---------------------- | ----------------------: | ----------------: |
| `2b833e5015ee` (before) |                     469 |               275 |
| `b726098ad308` (after)  |                       0 |                 0 |

The same investigation turned up a second defect: an evaluation is a child, so it was counted
when choosing the next draw index, which pushed a later continuation past a draw the cache
already held — evaluating a state made replaying its branch cost a fresh request. Only children
that came from sampling count now.

The branch under `2b833e5015ee` still holds the leaked tests, since states are immutable. It is
kept as the record of the bug; do not grade anything descended from it.

### Where to go next

The trajectory is a tree, so the interesting continuations are branches, not new runs. The last
useful state before the agent gave up is `a5f8193fa270`; a stronger model can be pointed at the
same place with `alaya resume a5f8193fa270 --model …`, and the results stay comparable because
both branches descend from the same root and are graded by the same overlay.
