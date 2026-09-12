# Alaya

A Lean 4 library for typed chat models and recorded agent runs. An agent's run is a tree of
immutable states in a content-addressed store: every model turn, every tool result, and every
workspace snapshot is kept exactly as it happened, so a run can be replayed, branched at any
point, evaluated against hidden tests, and interrupted by a person.

The library is organised in four layers, each documented on its own page.

```sh
lake build              # the alaya executable, in .lake/build/bin/
lake exe tests          # the test suite; pass a substring to run a subset
```

Besides the Lean toolchain named in `lean-toolchain`, `alaya` calls these programs on the host:

| Program | Used for |
| --- | --- |
| `curl` | every request to a model provider |
| `docker` | running an agent's commands, and evaluations, in a pinned container image |
| `/bin/sh`, `uname`, `cp`, `find` | running commands on the host, describing the host, and snapshotting a directory |

`docker` is needed only for trajectories created with `--image`; the rest are on any Unix host.
A grader given to `alaya eval` is a shell command of your own and brings its own dependencies.

## Documentation

[`docs/llm-api.md`](docs/llm-api.md) — the LLM API. `Alaya.Chat` is the typed data of the
chat-completions protocol: messages, tools, tool calls, structured output, requests, and
responses. `Alaya.Model` is one interface for anything that answers a request, built by wrapping
a provider transport in layers — retry, batching, sampling independence, a persistent response
cache — each configured separately.

[`docs/agent-api.md`](docs/agent-api.md) — the agent API. An agent records a log of events —
messages, model responses, tool observations — and is defined by a pure view that turns the log
into the dialogue the model is sent, a pure `next` that decides whether to sample, act, ask a
person, or stop, an `act` that runs a tool call in a workspace, and the tools it offers.

[`docs/trajectory-schema.md`](docs/trajectory-schema.md) — the trajectory and cache schema.
`Alaya.Trajectory` records a run as a tree of content-addressed states, each holding its
parent, the events it appends, and a snapshot of the workspace, so a run can be replayed,
forked, evaluated against hidden tests, and continued after a person intervenes. The page
specifies the state object, the store layout, the model cache entry, and every `alaya` command.

[`docs/miniswe.md`](docs/miniswe.md) — the MiniSwe design. `Alaya.Agent.MiniSwe` is the port of
mini-SWE-agent as one agent: prompts, tool schema, parsing, error messages, and the observation
envelope match the original to the byte, with the deviations listed and the command execution
reproducing Python's `Popen` semantics on the host or in a container.
