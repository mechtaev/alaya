import Alaya.Model

/-!
The agent API: the smallest set of operations a trajectory needs from an agent, independent of
any provider, tool set, or environment. See `docs/agent-api.md`.

An agent interacts with a stochastic **model** and an effectful **environment**. Everything it
does is recorded in a **log** of events — what was said to it, what it answered, what its tools
returned — exactly as it happened. The model never sees the log directly: a pure **view**
projects the log onto the dialogue the next sample is conditioned on. Keeping the two apart is
what lets a tool's output be recorded whole while the model is shown a truncation of it, and
lets the projection change without losing the record.

Concrete agents (see `Alaya.Agent.MiniSwe`) supply the four operations of `Agent`; the
trajectory (`Alaya.Trajectory`) drives them and persists the log.
-/

namespace Alaya.Agent

open Alaya (Result)

/-- The exact context a sample is conditioned on: the output of a view. -/
abbrev Dialogue := Array Chat.Message

/-- One thing that happened, recorded verbatim. -/
inductive Event where
  /-- Text placed in the context by something other than the model or a tool: the prompts that
  open a run, a person's message, or a legacy message whose raw form was never recorded. A view
  passes it through unchanged. -/
  | message (message : Chat.Message)
  /-- The model's turn, whether or not it parsed. Kept whole, so usage, finish reason, and a
  reasoning trace survive, and so a view can decide how a malformed turn is shown. -/
  | response (response : Chat.Response)
  /-- One tool call's result, as the agent's `act` produced it. Its shape is the agent's to
  define; the trajectory stores it and the view renders it. -/
  | observation (callId : String) (content : Lean.Json)
  deriving Inhabited

/-- The agent's memory: everything that happened, in order. -/
abbrev Log := Array Event

/-- A deterministic, total projection of the log onto the model's context. The invariant every
driver keeps: the response at log position `k` was sampled from `view (log.take k)`. -/
abbrev View := Log -> Dialogue

/-- Why a run stopped, and what it produced. -/
structure Outcome where
  /-- A short machine-readable status, e.g. "Submitted" or "LimitsExceeded". -/
  status : String
  /-- The agent's final output, when it submitted one. -/
  submission : String := ""
  deriving Repr, BEq, Inhabited

/-- What the loop should do next, decided from the log alone. -/
inductive Directive where
  /-- Draw the next response, conditioned on `view log`. -/
  | sample
  /-- Run one tool call; its result becomes an observation. -/
  | act (call : Chat.ToolCall)
  /-- Ask a person `question` and wait: the run stops here, and their answer is recorded as
  the observation of the call `callId` that asked. -/
  | ask (callId : String) (question : String)
  /-- The run is over. -/
  | done (outcome : Outcome)
  deriving Inhabited

/-- An agent, as the four things a driver needs from it. -/
structure Agent where
  /-- Names the agent and the configuration that shapes its view and control flow, for
  provenance. -/
  identity : Lean.Json
  /-- The tools offered to the model with every sample. -/
  tools : Array Chat.ToolDefinition
  /-- How the log is shown to the model. Pure and total. -/
  view : View
  /-- What to do next. Pure and total: everything it needs is in the log. -/
  next : Log -> Directive
  /-- Runs one tool call against the environment and returns the observation to record. The
  environment is whatever the agent closed over; a driver that wants it durable snapshots it
  after each act. -/
  act : Chat.ToolCall -> Result Lean.Json

namespace Log

/-- How many model turns the log holds. -/
def responses (log : Log) : Nat :=
  log.foldl (fun n event => match event with | .response _ => n + 1 | _ => n) 0

/-- The most recent model turn. -/
def lastResponse? (log : Log) : Option Chat.Response :=
  log.reverse.findSome? fun | .response r => some r | _ => none

/-- The events after the most recent model turn: what has happened in the current turn. -/
def sinceLastResponse (log : Log) : Array Event :=
  -- Walk newest-first, collecting until the response; consing restores oldest-first order.
  let rec collect (events : List Event) (acc : List Event) : List Event :=
    match events with
    | [] => acc
    | .response _ :: _ => acc
    | event :: rest => collect rest (event :: acc)
  (collect log.toList.reverse []).toArray

/-- The tool calls of the most recent turn that no observation has answered yet, in order. -/
def pending (log : Log) : Array Chat.ToolCall :=
  match log.lastResponse? with
  | none => #[]
  | some response =>
    let observed := log.sinceLastResponse.filterMap fun
      | .observation id _ => some id
      | _ => none
    response.toolCalls.filter fun call => !observed.contains call.id

/-- Every tool call made, in order — from responses, and from assistant messages placed
verbatim (a legacy record, or a person writing the model's turn). -/
def calls (log : Log) : Array Chat.ToolCall :=
  log.foldl (init := #[]) fun acc event =>
    match event with
    | .response r => acc ++ r.toolCalls
    | .message (.assistant _ calls _) => acc ++ calls
    | _ => acc

end Log

/-- How a reference run ended: with an outcome, or at a question a person has to answer. -/
inductive Stop where
  | outcome (outcome : Outcome)
  | question (callId : String) (question : String)
  deriving Inhabited

/-- The reference loop: follows the agent's directives until it stops, sampling from `view log`
and recording every event. A trajectory drives the same steps but persists each turn as a
state; this loop is the specification they agree on, and what a test runs an agent with. -/
partial def run (agent : Agent) (sample : Dialogue -> Result Chat.Response) (log : Log) :
    Result (Log × Stop) := do
  match agent.next log with
  | .done outcome => pure (log, .outcome outcome)
  | .ask callId question => pure (log, .question callId question)
  | .sample =>
    let response ← sample (agent.view log)
    run agent sample (log.push (.response response))
  | .act call =>
    let content ← agent.act call
    run agent sample (log.push (.observation call.id content))

end Alaya.Agent
