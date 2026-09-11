# Alaya

A Lean 4 library for typed chat models and recorded agent runs. An agent's run is a **tree of
immutable states** in a content-addressed store: every model turn, every tool result, and every
workspace snapshot is kept exactly as it happened, so a run can be replayed, branched at any
point, evaluated against hidden tests, and interrupted by a person.

The library is organised in four layers, each documented on its own page.

```sh
lake build              # the alaya executable
lake build benchmark    # the benchmark executable
lake exe tests          # the test suite; pass a substring to run a subset
```

Binaries land in `.lake/build/bin/`.

## LLM API

[`docs/llm-api.md`](docs/llm-api.md) — providers, the model interface, and caching.

One typed chat protocol (`Alaya.Chat`) and one interface for every model (`Alaya.Model`): a
request names a *sequence* of draws, and `sample` returns a stream along it. Behaviour is layered
by wrapping — retry with backoff, sequential or concurrent batching, sampling independence, and
a persistent response cache keyed by the exact request — so the same identity, request, and
draw index always yield the same response.

## Agent API

[`docs/agent-api.md`](docs/agent-api.md) — the minimal interface between an agent and the
machinery that runs it.

An agent keeps a **log** of events — messages placed verbatim, model responses, tool
observations — and a pure **view** that projects the log onto the dialogue the model is sent.
The view is where output is truncated and malformed turns are replaced; the log keeps
everything. Control is a pure `next : Log -> Directive` choosing between `sample`, `act`,
`suspend` (ask a person), and `done`; acting returns an observation whose shape the agent
defines. Five fields make an agent, and nothing else is needed to drive one.

## Trajectory and cache schema

[`docs/trajectory-schema.md`](docs/trajectory-schema.md) — what is stored, where, and what it
guarantees.

Each state is a content-addressed object holding its parent, the events it appends, and its
workspace snapshot. Continuing a state that already has *n* turn children asks the model cache
for draw *n*, so branches replay for free and a new continuation is always a fresh sibling.
People enter the tree as interventions, messages, and replies; evaluations are leaves that
overlay tests the agent never saw. The page specifies the state object (schema version 2), the
event encoding, the store layout, the model cache entry, and every `alaya` command.

## MiniSwe design

[`docs/miniswe.md`](docs/miniswe.md) — the port of mini-SWE-agent as one agent.

Prompts, tool schema, response parsing, error messages, and the observation envelope match
mini's to the byte, checked against fixtures rendered by mini's own templates. Two deliberate
deviations: a `submit` tool ends a run instead of a sentinel line in a command's output, so the
trajectory never has to read tool output; and the environment is a snapshot of the working
directory, so it can be branched. The executor that runs commands reproduces Python's `Popen`
semantics, on the host or in a container.

## A run, start to finish

```sh
export XMCP_API_KEY=...

root=$(alaya root "$(cat TASK.txt)" ./project --image python:3.12-slim)
alaya resume "$root" --model xmcp:ds/deepseek-v4-flash --echo-reasoning
alaya eval "$final" --tests ./hidden-tests --command "pytest -q" --timeout 1800

alaya tree                      # the forest
alaya show "$final" --view      # the log, then the context the model is sent
alaya html && open .alaya/report.html
```

A person can step in at any state: `alaya commit HASH DIR --tell "what I changed and why"`
records an edited workspace with a notice the model reads, and `alaya resume` continues from
there. Everything is addressed by hash and nothing is ever rewritten.
