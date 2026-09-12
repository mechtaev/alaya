# Example: one run of the mini agent on Bija, forked and graded

`trajectory.tar.gz` is a complete alaya data directory — the content-addressed store and the
model cache — holding a run of `Alaya.Agent.MiniSwe` on the Bija benchmark (`bija/`), a fork
with a hand-made intervention, and a grader's verdict on both branches. `report.html` is its
report, a single file to open in a browser. To use the commands below, unpack the archive first:

```sh
mkdir -p example/trajectory && tar -xzf example/trajectory.tar.gz -C example/trajectory
```

It shows, on a real task, what the four documentation pages describe: every model turn and
workspace snapshot recorded as an immutable state, a person changing the workspace and telling
the agent so, and a grader scoring a state the agent could never continue from.

## What it shows

```
46bce813368b  root      the task and the skeleton of the Bija project
  ...         10 turns  the agent reads SPEC.md, writes src/bija/cli.py, runs sample programs
  f2f6b32a81d2  turn    three sample programs still fail to parse
    591182d5114e  submit   [Submitted] "I'm out of time for a complete spec pass"
      aa05d3dee444  eval   [fail 29/232]
    d7f71105cd18  commit   a person fixes three parser bugs by hand and tells the agent
      ...           4 turns  the agent rewrites the file and breaks it
      80a182b272b5  submit   [Submitted] "Partially updated src/bija/cli.py"
        62f007b68972  eval   [fail 0/232]
```

The first branch is the agent's own run: eleven model turns, ending in a submission that the
agent itself describes as incomplete. Against the reference suite's 232 programs it scores 29.

The second branch starts from the same state the submission did. The person checked out that
state, fixed three parser bugs in `src/bija/cli.py` (statements begin with an expression, the
literals `yes`/`no`/`void` and the `depth` keyword were never consumed), and committed the
result with a message saying what was fixed, what remained, and that there was no time limit.
The agent read the message, rewrote the whole file in one command, produced an indentation
error, and submitted again after four turns. That state scores 0 of 232: the file no longer
parses.

Both verdicts hang off the states they judge, as leaves, and each one's workspace is the checkout
as the grader left it: the 232 reference programs in place of the 12 samples. No state the agent
ran from ever held them.

![The report: the tree on the left, the intervention state selected on the right](trajectory.png)

## How it was produced

From the repository root, with `alaya` built (`lake build`) and on the `PATH`, starting from an
empty `example/trajectory`. The agent ran in
`ghcr.io/astral-sh/uv:python3.12-alpine3.23` without network access, the default; the model was
`gpt-5.4-mini` at temperature 0 through the xmcp provider.

```sh
D=example/trajectory
M=xmcp:closeai/gpt-5.4-mini

# The root: the task statement and the skeleton, pinned to the image.
root=$(alaya root "$(cat example/bija/TASK.txt)" example/bija/skeleton --agent mini-swe \
  --image ghcr.io/astral-sh/uv:python3.12-alpine3.23 --data $D)

# The first branch, to its submission.
alaya resume $root --agent mini-swe --model $M --data $D
# ... 591182d5114e  [Submitted]

# Grade it against the reference suite.
alaya eval 591182d5114e --grader 'example/bija/grade.py {checkout} {out}' --timeout 1800 --data $D
# aa05d3dee444  fail 1 29/232  (76971 ms)

# The intervention: check out the last turn before the submission, edit by hand, commit with a message.
alaya checkout f2f6b32a81d2 /tmp/fix --data $D
$EDITOR /tmp/fix/src/bija/cli.py
alaya commit f2f6b32a81d2 /tmp/fix -m "Hand fix: expression-first statements, literal keywords, depth" \
  --tell "I fixed three parser bugs in src/bija/cli.py by hand. ..." --data $D
# d7f71105cd18

# The second branch, from the intervention, and its verdict.
alaya resume d7f71105cd18 --agent mini-swe --model $M --data $D
# ... 80a182b272b5  [Submitted]
alaya eval 80a182b272b5 --grader 'example/bija/grade.py {checkout} {out}' --timeout 1800 --data $D
# 62f007b68972  fail 1 0/232  (6993 ms)
```

## Reading it

```sh
D=example/trajectory
alaya tree --data $D                                  # the tree above
alaya show d7f71105cd18 --data $D                     # the intervention: message, log, workspace
alaya diff f2f6b32a81d2 d7f71105cd18 --data $D        # what the person changed
alaya show aa05d3dee444 --data $D                     # the verdict and the grader's output
alaya checkout aa05d3dee444 /tmp/evidence --evidence --data $D   # verdict.json, junit.xml, pytest.txt
alaya html example/report.html --agent mini-swe --hide .venv --hide __pycache__ --data $D
```

The archive holds only the durable parts of the data directory (`docs/trajectory-schema.md`
§5): the store's blobs and refs, and the model cache. The screenshot is the report with the
intervention state selected, taken by `screenshot.py`:

```sh
example/screenshot.py $PWD/example/report.html example/trajectory.png 1280 780 d7f71105cd18
```

The model cache is part of the data directory, so removing a branch with `alaya rm` and
resuming its parent again replays the recorded turns from the cache, without a request to the
provider. Continuing from a state that already has a turn child is a new draw, and needs the
provider and `XMCP_API_KEY`.

## What the run says about the agent

The agent measured itself by the sample programs it could run directly and never ran the suite:
`uv run pytest` needs to download pytest, and the container has no network by default. It
declared itself out of time on both branches; the mini agent has no time limit, and the
intervention said so. The rewrites that broke the file were single `cat > file <<'PY'` commands
of a few hundred compressed lines, a habit the intervention did not change.
