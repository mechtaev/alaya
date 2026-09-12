# Trajectory and cache schema

`Alaya.Trajectory` records an agent's run as a tree of immutable states in a content-addressed
store, and `Alaya.Cache` records every model response the run drew. Together they make a run
something you can branch, replay, evaluate, intervene in, and read back.

The trajectory is the same for every agent. Wherever an agent's prompts, tools, or view matter —
creating a root, taking a turn, rendering what the model was sent — the command line names the
agent with `--agent`; `mini-swe` (`docs/miniswe.md`) is the one available today, and the
examples below use it. Everything else — evaluating, intervening, replying, inspecting — is
agent-independent and takes no such flag.

## 1. States

A **state** is a point in a run: the log up to that point, and the workspace at that point. The
workspace is recorded as a **snapshot**: the content of the directory the agent acts in, written
into the content-addressed store as a tree of files and named by its hash.

```sh
# A root: the agent's opening prompts for the task, and a snapshot of ./project.
root=$(alaya root "make the test suite pass" ./project --agent mini-swe --image python:3.12-slim)
echo $root      # adbac197aea8…  a 64-hex hash; any unambiguous prefix names it from here on

alaya show adbac1          # the state: kind, parent, workspace hash, note, image, then its log
```

### The state object

A state is stored as one object with three parts:

- the hash of its **parent** state, or none for a root;
- the events it **appends** to the parent's log;
- the hash of its workspace snapshot, `workspace`.

The object is itself content-addressed: its hash covers those three parts, so a state's hash
names its whole history and its files, and nothing under a hash ever changes. The full log at a
state is the concatenation of `appended` along the path from the root (`logOf`), and the
workspace at a state is its `workspace`. A run is therefore a **tree** of states, and it only grows:
continuing from any state adds a child, and the original branch is untouched.

*A state object, and what its hash covers.*

```mermaid
flowchart LR
  subgraph S["state 4f2c8b1e0a33, the turn that ran pytest"]
    direction TB
    P["parent: adbac197aea8"]
    A["appended: response with call c1 bash pytest -q, observation c1"]
    E["workspace: b66cab13bd86"]
  end
  Parent["state adbac197aea8, the root<br/>no parent · the opening prompts · the project snapshot"]
  Tree["tree b66cab13bd86<br/>src/ · tests/ · pyproject.toml · …"]
  P --> Parent
  E --> Tree
```

### Kinds of state

Every state is one of seven kinds. The kind says what created the state and therefore what its
`appended` and `workspace` hold. Four kinds come from the `alaya` commands a person runs (`commit`,
`tell`, `reply`, `eval`); `root` comes from `root`; `turn` and `question` come from the agent,
driven by `resume` or `step`.

| Kind | Created by | `appended` | `workspace` |
| --- | --- | --- | --- |
| `root` | `alaya root` | the agent's opening prompts | the project as given |
| `turn` | one model turn | the response, and the observation of each call it made | the workspace after those calls ran |
| `question` | a model turn whose call asked a person | the response, and the observations of the calls before the ask | the workspace after those calls ran |
| `reply` | `alaya reply` | one observation: the person's answer to the question, verbatim | the parent's |
| `intervention` | `alaya commit` | nothing, or one notice when `--tell` is given | the directory the person edited |
| `message` | `alaya tell` | one notice carrying the person's text | the parent's |
| `evaluation` | `alaya eval` | nothing; the verdict is on the state itself | the parent's |

Two kinds constrain what may follow them. A `question` waits: only `reply` may be its child until
one exists. An `evaluation` is a leaf: it is a verdict on its parent, not a point a run can go on
from.

Besides the three parts, a state carries what the run needs to continue and what a reader wants
to know: the container `image?`, set on the root and inherited; a `note?` of provenance (the model spec for a turn, the task for a root, the note for
an intervention); the `outcome?` when the state ended the run; the `question?` a `question` is
waiting on; the `intervention?` record behind a notice; and the `evaluation?` verdict.

*The run used in the examples of this page, as a tree. Dashed: an evaluation, a leaf.*

```mermaid
flowchart TD
  root["adbac197aea8  root<br/>make the test suite pass"]
  t1["4f2c8b1e0a33  turn<br/>bash pytest -q"]
  c["9d0e11a2b7c4  intervention<br/>fixed the fixture by hand, with a notice"]
  t2["2c7f0a9e5d31  turn<br/>bash pytest -q"]
  t3["e5a1c3d9f802  turn<br/>submit  [Submitted]"]
  ev["7b19d4c2ff01  evaluation<br/>a grader ran pytest  [pass]"]
  q["c61754d16c7a  question<br/>Should I keep the old API?  [Waiting]"]

  root --> t1
  t1 --> c --> t2 --> t3 --> ev
  t1 --> q

  classDef evalStyle stroke-dasharray: 5 5
  class ev evalStyle
```

```
$ alaya tree
adbac197aea8  root  make the test suite pass
  4f2c8b1e0a33  bash  pytest -q
    9d0e11a2b7c4  commit  fixed the fixture by hand
      2c7f0a9e5d31  bash  pytest -q
        e5a1c3d9f802  submit  done  [Submitted]
          7b19d4c2ff01  eval  [pass]  cp -R ./hidden-tests/. {checkout}/ && pytest -q
    c61754d16c7a  ask  Should I keep the old API?  [Waiting]
```

Each line is a state: its hash, its kind (a turn shows its first tool call), and what closed it —
an outcome, or a question still waiting. Indentation shows children; `4f2c8b1e0a33` has two, a
person's commit and a turn that asked a question.

## 2. Turns, draws, and forks

### A turn

A **turn** is what `resume` and `step` add to the tree: one model sample and the tool calls that
follow it, until the agent's `next` wants to sample again, stops, or asks a person. Given a parent
state, the trajectory:

1. materializes the parent's workspace snapshot into the working directory;
2. builds the request — the agent's view of the parent's log, with the agent's tools — and draws
   one response (how it picks *which* draw is the subject of the next part);
3. follows the agent's directives: for each `act`, runs the call in the working directory,
   records the observation, and snapshots the directory;
4. writes one child state: the response and observations as `appended`, the last snapshot as
   `workspace`, and, if the agent stopped, the `outcome?` or `question?`.

*One turn, from a parent state to its child.*

```mermaid
flowchart TD
  P["parent state<br/>log L · workspace W"]
  M["materialize W into the working directory"]
  R["request := view L, with the tools<br/>response := draw from the model"]
  A["for each act: run the call · record the observation · snapshot the directory"]
  C["child state<br/>appended = response + observations · workspace = last snapshot"]
  P --> M --> R --> A --> C
```

```sh
alaya step 4f2c8b --agent mini-swe --model xmcp:ds/deepseek-v4-flash      # exactly one turn
alaya resume 4f2c8b --agent mini-swe --model xmcp:ds/deepseek-v4-flash    # turns until the run ends or asks
```

`step` prints the new child's hash; `resume` prints one line per new state and ends with
`done: Submitted`, or with the question it stopped at.

### Which draw

A model request does not have one answer; it has a sequence of draws, and the model cache (§7)
stores that sequence per request, indexed from 0. Every turn child of a state was sampled from
the *same* request — the parent's log viewed the same way, with the same tools — so the children
of a state are, in order, draws 0, 1, 2, … of one sequence.

The trajectory therefore never decides "new" or "reuse" itself. It counts the parent's children
of kind `turn` or `question` — call the count `n` — and asks the cache for draws `0` to `n`
(`nextN (n+1)`), then uses draw `n`. The cache does the rest:

- if its entry already holds draw `n`, it returns it without a provider call;
- if not, it asks the provider for the missing draws, appends them to the entry, and returns them.

Children a person makes — `reply`, `message`, `intervention` — and evaluations are not counted:
they asked the model nothing, and counting them would skip a draw the cache holds.

*Which draw a continuation receives, by what the state already has under it.*

```mermaid
flowchart LR
  subgraph one["the root has no turn children: n = 0"]
    direction TB
    S1["adbac197aea8 root"] -->|"draw 0"| T1["4f2c8b1e0a33 turn<br/>bash pytest -q"]
  end
  subgraph two["2c7f0a has one turn child: n = 1"]
    direction TB
    S2["2c7f0a9e5d31 turn"] -->|"draw 0, already there"| T2a["e5a1c3d9f802 turn<br/>submit  [Submitted]"]
    S2 -->|"draw 1, new: a fork"| T2b["a new turn"]
  end
  subgraph three["4f2c8b has a question and a commit: n = 1"]
    direction TB
    S3["4f2c8b1e0a33 turn"] -->|"draw 0, already there"| T3a["c61754d16c7a question"]
    S3 -.->|"not counted"| C3["9d0e11a2b7c4 intervention"]
    S3 -->|"draw 1, new"| T3b["a new turn"]
  end
```

```sh
alaya step 2c7f0a --agent mini-swe --model M   # 2c7f0a has one turn child, e5a1c3 (draw 0),
                                               # so this is draw 1: a new sample, a fork
alaya step 2c7f0a --agent mini-swe --model M   # draw 2
alaya tree                                     # 2c7f0a now has three turn children, siblings
```

Replay needs no command of its own. If the second `step` had been interrupted after the model
answered but before the child was written, running it again asks for draw 1 again and receives
the recorded response without a provider call. Likewise `alaya rm HASH` followed by a `resume`
from its parent reproduces the deleted branch draw for draw, as long as `.alaya/cache` is kept.

## 3. People in the tree

A run is not only the agent's. A person can change the workspace, tell the agent something, and
answer a question the agent asks; a supervising program can do the same through the command
line. Each of these is a state like any other — a child with its own `appended` events and
`workspace` — so what a person did is recorded in the same tree, is addressable by hash, and can
be forked like a model turn.

### Changing the workspace: `commit`

`alaya commit HASH DIR [-m NOTE] [--tell TEXT]` snapshots the directory `DIR` and records it as
an `intervention` child of `HASH`. The child's log is the parent's: without `--tell`, nothing is
appended, and the agent learns of the change only by running commands, as it would if the files
had changed under it. `-m NOTE` is provenance for the reader of the tree, not for the model.

With `--tell TEXT`, one event is appended: a user message carrying a **notice**. The notice is
rendered from a record the state also keeps, `intervention? = { message, changed }`, where
`changed` lists the paths that differ between the parent's workspace and `DIR`, one `+ path`,
`- path`, or `M path` line each:

```
<intervention>
A person changed the workspace while you were paused:
  M src/bija/cli.py
  + tests/extra.bj
I fixed the identifier lookup; re-run every sample without set -e.
</intervention>
```

The envelope is fixed so the model can tell a person's notice from the task and from tool
output; the text inside is verbatim.

```sh
alaya checkout 4f2c8b ./fix                  # the state's files, to edit by hand
$EDITOR ./fix/src/app.py
alaya commit 4f2c8b ./fix -m "fixed the fixture" \
  --tell "I fixed the identifier lookup in src/app.py; re-run the suite."
# 9d0e11a2b7c4
alaya resume 9d0e11 --agent mini-swe --model M   # the agent continues, having read the notice
```

```mermaid
flowchart LR
  t1["4f2c8b1e0a33  turn<br/>bash pytest -q"] --> c["9d0e11a2b7c4  intervention<br/>workspace = ./fix, appended = the notice"]
  c -.-> t2["2c7f0a9e5d31  turn<br/>the agent's next turn reads the notice"]
  classDef new stroke-dasharray: 5 5
  class t2 new
```

### Sending a message: `tell`

`alaya tell HASH TEXT` is the same notice without a workspace change: a `message` child whose
`workspace` is the parent's and whose one appended event is the user message, with the header
"A person sent you a message while you were paused." and no path list.

Both notices are `Event.message`, which every view passes through unchanged, so the model sees
exactly the text above on its next turn. Neither child counts as a draw (§2): the next
continuation from the parent still receives the draw its turn children imply.

```sh
alaya tell 2c7f0a "The failing test is the one to trust; do not edit tests/."
# 3a9b7e2c1d40                                  a message child of 2c7f0a
alaya resume 3a9b7e --agent mini-swe --model M
```

```mermaid
flowchart LR
  t2["2c7f0a9e5d31  turn<br/>bash pytest -q"] --> m["3a9b7e2c1d40  message<br/>workspace unchanged, appended = the notice"]
  m -.-> n["a new turn<br/>from alaya resume 3a9b7e"]
  classDef new stroke-dasharray: 5 5
  class n new
```

### Being asked: `question` and `reply`

An agent that offers a tool for asking a person returns the `ask callId question` directive when
the model calls it (`docs/agent-api.md` §3). The trajectory then finishes the turn early and
records it as a `question` state:

- `appended` holds the response and the observations of the calls *before* the ask; the calls
  after it never ran;
- `question? = { callId, text }` names the asking call and carries the text for the person;
- `resume`, `step`, `commit`, and `tell` refuse the state until it is answered.

`alaya reply HASH TEXT` records the answer as a `reply` child: the parent's workspace, and one
appended event, `Event.observation callId TEXT`, the answer as the asking call's result,
verbatim. The next turn from the reply child continues with the calls that were still pending,
exactly as if the tool had returned the person's words.

*A question and its reply, as events in the log.*

```mermaid
flowchart TD
  subgraph Q["c61754 question state, appended"]
    direction TB
    R["response: calls c1 bash, c2 ask_user, c3 bash — c2 asks: Should I keep the old API?"]
    O1["observation c1: the command's output"]
    R --> O1
  end
  subgraph A["8f2e6b reply state, appended"]
    direction TB
    O2["observation c2: Keep it; add the new one beside it."]
  end
  subgraph N["the next turn, appended"]
    direction TB
    O3["observation c3: c3 runs now"]
    R2["response: …"]
    O3 --> R2
  end
  O1 --> O2 --> O3
```

Answering the same question twice makes two `reply` siblings, which is a fork on the answer.
`alaya waiting` lists every question no child has answered.

```sh
$ alaya resume 4f2c8b --agent mini-swe --model M
c61754d16c7a  ask  "Should I keep the old API?"  [Waiting]
$ echo $?
3
$ alaya waiting
c61754d16c7a  "Should I keep the old API?"
$ alaya reply c61754 "Keep it; add the new one beside it."
8f2e6b0d4a17
$ alaya resume 8f2e6b --agent mini-swe --model M
```

```mermaid
flowchart LR
  t1["4f2c8b1e0a33  turn"] --> q["c61754d16c7a  question<br/>Should I keep the old API?  [Waiting]"]
  q --> r["8f2e6b0d4a17  reply<br/>appended = observation c2: Keep it; add the new one beside it."]
  r -.-> n["a new turn<br/>c3 runs, then the model is sampled"]
  classDef new stroke-dasharray: 5 5
  class n new
```

### A program in the person's seat

Everything above is a command, so a program — a supervising agent, say — can play the person's
part by running `alaya` as a subprocess. `resume` and `step` exit with status `0` when the run
ended and `3` when it stopped at a question; with `--json` each state they print is one object
with `state`, `kind`, `outcome`, and `question`, and `waiting --json` prints `{state, question}`
per open question. The loop is: resume; on exit 3 read the question, decide, `reply`; resume
from the reply's hash.

```sh
alaya resume "$hash" --agent mini-swe --model M --json
# {"state":"c61754…","kind":"question","outcome":null,"question":"Should I keep the old API?"}
# exit status 3
reply=$(alaya reply c61754 "Keep it; add the new one beside it.")
alaya resume "$reply" --agent mini-swe --model M --json
```

## 4. Evaluation

An **evaluation** is a verdict on a state, produced by a program of the person's choosing and
recorded as a leaf child. The trajectory does not know what a verdict means for a given task;
it knows how to hand a program the state's files, collect what the program says, and keep it.

### The grader

A grader is a shell command run on the host. Before it runs, the trajectory materializes the
state's workspace into a fresh directory, the **checkout**, and creates an empty **output
directory**; the command receives both by substitution:

| Placeholder | Expands to |
| --- | --- |
| `{checkout}` | the directory holding the state's files; also the command's working directory |
| `{out}` | an empty directory for anything the grader wants kept |

The grader may do anything to the checkout: copy tests over it, apply a patch, build it, start a
container with it mounted, or rebuild a clean project elsewhere and carry only the agent's edits
across. None of that touches a state. The checkout is discarded when the grader finishes, and the
evaluation's own `workspace` is its parent's, so the tree records what was graded and the
grader's verdict, never the grader's working files.

### The verdict

When the grader exits, the trajectory records:

| Field | Meaning |
| --- | --- |
| `grader` | the command as given, placeholders unexpanded |
| `returncode`, `elapsedMs` | the exit status and the wall-clock time |
| `output` | stdout and stderr, merged, truncated to 20 000 characters |
| `evidence?` | a snapshot of `{out}`, when the grader wrote anything there |
| `summary?` | the contents of `{out}/verdict.json`, when the grader wrote one |

A state **passed** when `summary?` has a boolean `passed` field and it is true; otherwise when the
exit status is zero. A grader that only runs a test suite needs no `verdict.json`: the suite's
exit status is the verdict. A grader with more to say — per-test statuses, a score, a reason —
writes `verdict.json` with `passed` and any other fields, and puts its reports and logs beside
it; `alaya show` prints the summary and names the evidence, and `alaya checkout HASH DIR
--evidence` yields the files.

*An evaluation: the grader runs on the host over a checkout; the state records the verdict.*

```mermaid
flowchart LR
  S["state e5a1c3<br/>workspace W"] -->|"materialize W"| C["checkout<br/>(discarded afterwards)"]
  G["grader command<br/>{checkout} {out}"] --> C
  G --> O["out/<br/>verdict.json · report.md · …"]
  C -.->|"exit status, output"| E["evaluation 7b19d4<br/>grader · returncode · output · summary · evidence"]
  O -.->|"snapshot"| E
  S --> E
```

Re-evaluating a state with the same grader command returns the existing node; `--force` runs it
again and adds a sibling. Different grader commands are different evaluations of the same state.

```sh
# A hidden test suite, copied over the checkout; the suite's exit status is the verdict.
alaya eval e5a1c3 --grader 'cp -R ./hidden-tests/. {checkout}/ && pytest -q' --timeout 1800
# 7b19d4c2ff01  pass  (48210 ms)

# A patch of the tests against the original files, then the suite.
alaya eval e5a1c3 --grader 'patch -p1 -d {checkout} < ./tests.diff && pytest -q tests/test_foo.py'

# A grading program with its own verdict: it rebuilds a clean project from a source it trusts,
# carries the agent's edits across, and writes verdict.json and a report into {out}.
alaya eval e5a1c3 --grader 'grade-project --candidate {checkout} --source ./benchmark --report-dir {out}'

alaya show 7b19d4                        # verdict, summary, evidence hash, and the grader's output
alaya checkout 7b19d4 ./report --evidence  # the grader's report files
```

## 5. On disk

The data directory (`--data D`, default `.alaya`) holds everything one set of runs needs:

| Path | Contents |
| --- | --- |
| `D/store/blobs/<2 hex>/<64 hex>` | every object, addressed by the SHA-256 of its bytes: state objects, tree objects, file contents, link targets |
| `D/store/refs/state.<hex>` | pins a state object; the set of these *is* the forest |
| `D/store/refs/workspace.<hex>` | pins a tree a state refers to — a workspace, or an evaluation's evidence — so `gc` keeps it |
| `D/store/cache/`, `D/store/checkouts/` | the snapshot stat cache and the record of what was last materialized where; performance only |
| `D/store/tmp/` | staging for atomic writes (write, then rename) |
| `D/cache/v1/<hash>.json` | model response cache entries (§7) |
| `D/work/` | the working directory; wiped and re-materialized at every checkout, holds nothing durable |
| `D/eval/` | a grader's checkout and output directory; emptied before every evaluation |

A workspace is a git-style Merkle tree: a **tree object** is the JSON array of its entries
`{"name", "type": "file"|"exec"|"link"|"dir", "hash"}`, sorted by name so its serialization is
canonical; a file entry's hash addresses the content blob, a directory's the sub-tree. Unchanged
subtrees keep their address across snapshots, so a snapshot costs only the objects along changed
paths and diffing skips identical subtrees. Snapshots are stat-cached, hashed in parallel,
record symlinks and executable bits, and can ignore paths. Materializing is incremental against
the recorded checkout and, by default, re-captures the destination first (`verify`), because the
record goes stale the moment the agent writes; without that, a fork would start from the
abandoned branch's files.

`Store.gc` deletes every blob unreachable from a ref. `rm HASH` deletes a subtree by dropping its
`state.` refs, re-pinning `workspace.` refs from the survivors, and collecting.

*What is on disk: the data directory, and how state and tree objects reference each other in the content-addressed store.*

```mermaid
flowchart TD
  alayaRoot[".alaya/"]
  storeDir["store/"]
  modelCacheDir["cache/, model response cache"]
  workDir["work/, agent's working directory"]
  alayaRoot --> storeDir
  alayaRoot --> modelCacheDir
  alayaRoot --> workDir

  blobsDir["blobs/, content-addressed objects"]
  refsDir["refs/, named pointers"]
  statCacheDir["cache/, per-workspace stat cache"]
  checkoutsDir["checkouts/, last materialized where"]
  tmpDir["tmp/, atomic-write staging"]
  storeDir --> blobsDir
  storeDir --> refsDir
  storeDir --> statCacheDir
  storeDir --> checkoutsDir
  storeDir --> tmpDir

  blobLayout["blob path: blobs/, 2-hex subdir, 64-hex filename"]
  blobsDir --> blobLayout

  stateObj["state object, JSON"]
  parentState["parent state object"]
  envTree["tree object, the workspace"]
  blobLayout -.stores.-> stateObj
  blobLayout -.stores.-> envTree
  stateObj -->|parent hash| parentState
  stateObj -->|workspace hash| envTree

  treeEntry["entry: name, type file or exec or link or dir, hash"]
  envTree --> treeEntry
  fileBlob["file content blob"]
  subTree["sub-tree object"]
  treeEntry -->|file, exec, or link| fileBlob
  treeEntry -->|dir| subTree

  stateRef["state.hex ref"]
  envRef["workspace.hex ref"]
  refsDir --> stateRef
  refsDir --> envRef
  stateRef -->|pins| stateObj
  envRef -->|pins| envTree

  cacheEntry["cache/v1/hash.json: key + responses[]"]
  modelCacheDir --> cacheEntry

  subgraph Notes[" "]
    direction TB
    gcNote["Store.gc keeps exactly what is reachable from refs"]
    workNote["work/ is wiped and re-materialized at every checkout, and holds nothing durable"]
  end
```

```
$ ls .alaya
cache  store  work
$ ls .alaya/store
blobs  cache  checkouts  refs  tmp
$ ls .alaya/store/refs | head -3
state.adbac197aea8…
state.4f2c8b1e0a33…
workspace.b66cab13bd86…
```

## 6. The state object

A state object is compact JSON. Field order is canonical (sorted keys), so equal states have
equal hashes.

| Field | Type | Meaning |
| --- | --- | --- |
| `v` | 1 | schema version; a reader refuses any other |
| `parent` | hex or null | the parent state |
| `workspace` | hex | the workspace tree |
| `kind` | string | one of the kinds in §1 |
| `appended` | array of events | what this state adds to the parent's log |
| `outcome` | `{status, submission}` or null | when this state ended the run |
| `note` | string or null | provenance |
| `image` | string or null | the pinned container image, inherited |
| `evaluation` | object or null | `{grader, returncode, elapsed_ms, output, evidence, summary}` on an evaluation |
| `intervention` | object or null | `{message, changed: ["M path", "+ path", "- path", …]}` on a state that carried a notice |
| `question` | object or null | `{call_id, text}` on a waiting state |

An **event** is one of:

```json
{"type": "message", "message": {"role": "system"|"user", "content": "…"}}
{"type": "message", "message": {"role": "assistant", "content": …, "reasoning": …, "tool_calls": [call…]}}
{"type": "message", "message": {"role": "tool", "tool_call_id": "…", "content": <json>}}
{"type": "response", "response": {"content", "tool_calls": [call…], "reasoning", "finish_reason", "usage": {"input", "output", "total"}}}
{"type": "observation", "call_id": "…", "content": <json>}
```

where a **call** is `{"id", "name", "arguments": <json>, "invalid_arguments": string|null}` —
`invalid_arguments` keeps the raw text when the provider's arguments were not JSON, so the
dialogue sent back to the model is byte-identical to what it produced. An observation's
`content` is whatever the agent's `act` returned; the trajectory never reads it.

`alaya show HASH` prints a state's fields and its full log in a readable form; with `--view` and an
agent it also prints the dialogue that agent's view makes of the log, which is what the model is
sent from that state:

```sh
alaya show 4f2c8b
alaya show 4f2c8b --view --agent mini-swe
alaya diff adbac1 4f2c8b        # the workspace changes between two states, one path per line
```

## 7. The model cache entry

`D/cache/v1/<hash>.json`, where `hash` is Lean's generic hash of the cache key:

```json
{
  "version": 1,
  "key": "<compress {model: <identity>, structured_output: <mode>, request: <Request.toJson>}>",
  "responses": [
    {"content": …, "tool_calls": [call…], "usage": {…}, "finish_reason": …, "reasoning_content": …},
    …
  ]
}
```

`responses[i]` is draw `i` of that request under that model identity. The stored key is checked
against the file name on load, and a corrupt entry reads as empty and is replaced on the next
successful sample. The key contains the full
request, so anything that changes what the model is sent — the view, the tool list, the model
identity including options such as reasoning echo — changes the key, and a forest recorded under
one will not replay under another.

```
$ ls .alaya/cache/v1 | head -2
1180723829451067366.json
5029385371209364131.json
```

The directory is safe to keep between runs and across trajectories in the same data directory:
an entry is only ever appended to.

## 8. Commands

```
alaya root TASK PROJECT --agent A [--image IMAGE]      create a root from a project directory
alaya root TASK --agent A --image IMAGE --path PATH    …or from a path inside the image
alaya resume HASH --agent A --model P:M                grow one continuation until it ends or asks
alaya step   HASH --agent A --model P:M                advance exactly one turn
alaya eval   HASH --grader CMD [--timeout S] [--force]   run a grader over a checkout; record the verdict
alaya commit HASH DIR [-m NOTE] [--tell TEXT]    record a hand-edited workspace as a child
alaya tell   HASH TEXT                           send the agent a message, as a child
alaya reply  HASH TEXT                           answer the question a state is waiting on
alaya waiting                                    list every unanswered question
alaya checkout HASH DIR [--evidence]             materialize a state's workspace (or an evaluation's evidence) into DIR
alaya tree                                       show the whole forest
alaya show HASH [--view --agent A]               metadata, the log, and optionally the view
alaya diff A B                                   workspace changes between two states
alaya html [FILE] --agent A [--hide DIR]         write the forest as one self-contained page
alaya rm HASH                                    delete a subtree and reclaim blobs
```

Every command takes `--data D` and `--json` where it prints states. `--agent A` names the agent
where its prompts, tools, or view matter; `mini-swe` is the one available. `root` takes `--image`,
`--container-user`, and `--network`; `resume` and `step` take `--model`,
`--temperature`, `--echo-reasoning`, `--network`, and the DGX flags `--url`/`--port`; `eval`
takes `--timeout` (default 900 s) for the grader and `--force`. The image is resolved to a digest at `root`
and recorded; `resume` uses it and refuses an `--image` that resolves to anything else.
A container runs with **no network** unless `--network` names one (`--network bridge` is
Docker's default network): an agent with network access can go looking for its own reference
solution, so an image should carry what a task legitimately needs.

Exit status: 0 when a run ended, 3 when it stopped at a question, 1 on error. Concurrent runs
need separate data directories: the work directory and the cache are not shared safely.

## 9. Invariants

- A state's hash covers its parent, its appended events, and its workspace; nothing under a
  hash ever changes.
- `logOf state` is the concatenation of `appended` from the root; the request the model was
  sent to produce a turn is `agent.view (logOf parent)` with `agent.tools`.
- Continuing from a state with `n` turn-or-question children asks for draw `n`; other children
  never consume a draw.
- A state's workspace is the snapshot taken after its last act; an evaluation's is its parent's,
  and nothing continues from it.
- A waiting state grows only by `reply`.
- The trajectory reads no observation's content and knows no tool's name.
