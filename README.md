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
alaya root TASK PROJECT                          create a root state from a project directory
alaya resume HASH --model P:M                    grow one continuation to completion
alaya step   HASH --model P:M                    advance exactly one model turn
alaya commit HASH DIR [-m NOTE]                  record a hand-edited workspace as a child
alaya checkout HASH DIR                          materialize a state's workspace into DIR
alaya tree                                       show the whole forest
alaya show HASH                                  show a state's metadata and dialogue
alaya diff A B                                   workspace changes between two states
alaya rm HASH                                    delete a subtree and reclaim blobs
```

### Two directories, kept strictly apart

| Flag       | Default       | Contents                                                       |
| ---------- | ------------- | -------------------------------------------------------------- |
| `--data D` | `.alaya`      | everything durable: the store (`D/store`) and model cache (`D/cache`) |
| `--work W` | `.alaya-work` | the directory the agent runs its commands in                    |

`--data` is the only place anything is kept. It must sit outside `PROJECT`, since the store
cannot live inside the tree it snapshots.

`--work` holds nothing durable. Every turn begins by **wiping it** and re-materializing the
parent state's snapshot into it, so anything there that was not captured into the store is lost.
Only `resume` and `step` use it, and `alaya` refuses a `--work` that is inside `--data`, or that
contains it. Give concurrent runs separate work directories.

### Sampling, caching, and branching

Responses are cached in `D/cache`, keyed by the request *and a draw index*. Growing a
continuation from a state with `n` children asks for draw `n`, past every recorded draw — so
existing branches replay from cache deterministically, a new continuation is always a fresh
sibling, and an interrupted run resumes without re-billing the turns it already made.

`--temperature T` (default `0.0`) sets the sampling temperature.

### An example

```sh
export DGX_API_KEY=EMPTY

# Snapshot a project as the root of a new trajectory.
root=$(alaya root "make the test suite pass" ./myproject)

# Run to completion, printing each new state as it appears.
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

Every command takes `--data`; `resume` and `step` additionally take `--work`, `--model`,
`--temperature`, and the DGX flags `--url`/`--port`.

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
