# Agent API

`Alaya.Agent` fixes the minimal assumptions about an agent that trajectory management
(`docs/trajectory-schema.md`) relies on:

- the agent's history is a **log** of events — messages, model responses, tool observations;
- what the model is sent is a pure function of the log, the agent's **view**;
- what happens next — sample, run a tool call, ask a person, stop — is a pure function of
  the log, the agent's **next**;
- a tool call is run by the agent's **act**, which returns the observation to record;
- the **tools** offered to the model are fixed for the agent.

An agent is a value of the record `Agent` holding these; `Alaya.Agent.MiniSwe` (`docs/miniswe.md`)
is one.

## 1. The log

The log is the record of a run: everything that was put in front of the model, everything the
model answered, and everything its tools returned, in order and unchanged.

```lean
inductive Event where
  | message (message : Chat.Message)                -- text placed as is: a prompt, a person's note
  | response (response : Chat.Response)             -- the model's turn, exactly as it came back
  | observation (callId : String) (content : Json)  -- a tool call's result, as the agent produced it

abbrev Log := Array Event
```

A **message** is text someone other than the model or a
tool placed in the conversation: the prompts that open a run, a notice from a person. A
**response** is a model turn, as it came back. An
**observation** is what one tool call returned, named by the call's id, in whatever JSON shape the
agent chose to record.

*A short run as a log.*

```mermaid
flowchart LR
  E1["1 message<br/>system: You can run bash."]
  E2["2 message<br/>user: List the files."]
  E3["3 response<br/>Listing. + call c1: bash ls"]
  E4["4 observation c1<br/>{output: a.txt\nb.txt\n, returncode: 0}"]
  E5["5 response<br/>call c2: submit"]
  E1 --> E2 --> E3 --> E4 --> E5
```

```lean
let log : Log := #[
  .message (.system "You can run bash."),
  .message (.user "List the files."),
  .response { content? := some "Listing.", toolCalls := #[{ id := "c1", name := "bash", arguments := .mkObj [("command", "ls")] }] },
  .observation "c1" (.mkObj [("output", "a.txt\nb.txt\n"), ("returncode", 0)]),
  .response { toolCalls := #[{ id := "c2", name := "submit", arguments := .mkObj [("message", "done")] }] }]

log.responses        -- 2
log.calls            -- #[c1, c2]
log.pending          -- #[c2]: the last response's calls with no observation yet
```

`Alaya.Agent.Log` provides the functions that read these facts off a log: `responses` (how many
model turns), `lastResponse?`, `sinceLastResponse` (the events of the current turn), `pending`
(the last response's calls no observation has answered), and `calls` (every tool call made).

## 2. The view

The view is the function that turns the log into the dialogue the model is sent. It applies the
agent's presentation policies: a long tool output is shown truncated; a response with no valid
tool call is shown as an error message rather than as the response; an old observation may be
left out to save context.

`view : Log -> Dialogue` is pure and total. Its domain is the whole log, not a
single event, because "elide observations older than N turns" needs position and "stay under a
token budget" needs everything. One rule keeps it pure: anything non-deterministic — a
model-written summary, say — is itself an event in the log, and the view merely places it.

The invariant: **the response at log position k was sampled from `view (log.take k)`**. Because
the view is pure and the log is persisted, the request the model saw at any step is recomputable,
and nothing about it needs to be stored.

*An example: one agent's view of a seven-event log.*

```mermaid
flowchart LR
  subgraph LOG["Log (the record)"]
    direction TB
    L1["Event.message (system prompt)"]
    L2["Event.message (user: the task)"]
    L3["Event.response (assistant text + bash 'cat big.log')"]
    L4["Event.observation (c1: output 12000 chars, returncode 0) - recorded whole"]
    L5["Event.response (no tool call: a format error)"]
    L6["Event.message (user: a person's intervention notice)"]
    L7["Event.response (assistant + bash 'pytest')"]
  end

  subgraph VIEW["view log (the dialogue)"]
    direction TB
    V1["system message (passed through)"]
    V2["user message (passed through)"]
    V3["assistant message with the tool call"]
    V4["tool message: output_head 5000 chars + output_tail 5000 chars + elided_chars 2000 - truncated for the model"]
    V5["user message with the format-error text - response dropped, error shown instead"]
    V6["user message (passed through)"]
    V7["assistant message with the tool call"]
  end

  L1 --> V1
  L2 --> V2
  L3 --> V3
  L4 --> V4
  L5 --> V5
  L6 --> V6
  L7 --> V7
```

## 3. Directives and actions

What happens next is decided from the log alone: `next : Log -> Directive` is pure and total, so
a resumed run behaves exactly as the run it continues. The four directives are everything a
run consists of:

```lean
inductive Directive where
  | sample                                          -- draw the next response from view log
  | act (call : Chat.ToolCall)                      -- run one tool call
  | ask (callId : String) (question : String)       -- ask a person and wait for the answer
  | done (outcome : Outcome)                        -- the run is over
```

`ask` is how an agent asks a person something. The trajectory records the question and stops;
the person's answer arrives later as the observation of the asking call, and the log continues
as if the tool had returned.

`act : Chat.ToolCall -> Result Json` runs one call against the environment and returns the
observation to record. The shape of the observation is the agent's to define, and its view is
what renders it. An agent that fails to execute a call returns an observation saying so rather
than throwing, so that a run survives a failed command.

## 4. The agent record and the reference loop

```lean
structure Agent where
  identity : Lean.Json                   -- who this is and how it is configured, for provenance
  tools : Array Chat.ToolDefinition      -- offered on every sample
  view : View
  next : Log -> Directive
  act : Chat.ToolCall -> Result Lean.Json
```

`Agent.run agent sample log` is the reference loop: follow `next` until it stops, sampling from
`view log` and pushing every event. It returns the final log and a `Stop`: an `outcome`, or a
`question` a person has to answer. A trajectory drives the same steps but persists each **turn**
— one sample and the acts that follow it — as a state, and snapshots after every act. Tests run
an agent through `Agent.run` with a scripted `sample` and no store at all.

*The reference loop `Agent.run`, and how a trajectory drives the same steps.*

```mermaid
flowchart TD
  NEXT{"next log (pure)"}

  NEXT -->|sample| S1["dialogue := view log"]
  S1 --> S2["response := model.sample dialogue"]
  S2 --> S3["log.push (response r)"]
  S3 --> NEXT

  NEXT -->|"act call"| A1["content := agent.act call"]
  A1 --> A2["log.push (observation call.id content)"]
  A2 --> NEXT

  NEXT -->|"ask callId question"| SU["Stop.question: a person must answer"]
  NEXT -->|"done outcome"| DO["Stop.outcome"]

  classDef terminal fill:#eee,stroke-dasharray: 5 5
  class SU,DO terminal
```
