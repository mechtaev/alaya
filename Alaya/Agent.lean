import Alaya.Model

/-! The agent API: the log of events, the view of it the model is sent, and the operations a
trajectory drives an agent with. See `docs/agent-api.md`. -/

namespace Alaya.Agent

open Alaya (Result)

/-- The context a sample is conditioned on: the output of a view. -/
abbrev Dialogue := Array Chat.Message

/-- One thing that happened, recorded verbatim. -/
inductive Event where
  /-- Text placed in the context by something other than the model or a tool. -/
  | message (message : Chat.Message)
  /-- The model's turn, whether or not it parsed. -/
  | response (response : Chat.Response)
  /-- One tool call's result, in whatever shape the agent's `act` produced. -/
  | observation (callId : String) (content : Lean.Json)
  deriving Inhabited

/-- Everything that happened, in order. -/
abbrev Log := Array Event

/-- A pure, total projection of the log onto the model's context. -/
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
  | sample
  | act (call : Chat.ToolCall)
  /-- Stop and wait for a person; their answer is recorded as the observation of `callId`. -/
  | ask (callId : String) (question : String)
  | done (outcome : Outcome)
  deriving Inhabited

/-- The directory an agent's tools act in. -/
structure Workspace where
  dir : System.FilePath
  deriving Inhabited

structure Agent where
  /-- The agent and its configuration, for provenance. -/
  identity : Lean.Json
  tools : Array Chat.ToolDefinition
  view : View
  next : Log -> Directive
  /-- Runs one tool call in the workspace and returns the observation to record. -/
  act : Workspace -> Chat.ToolCall -> Result Lean.Json

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
verbatim by a person writing the model's turn. -/
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

/-- The reference loop: follows the agent's directives until it stops, recording every event.
A trajectory drives the same steps but persists each turn as a state. -/
partial def run (agent : Agent) (workspace : Workspace) (sample : Dialogue -> Result Chat.Response)
    (log : Log) : Result (Log × Stop) := do
  match agent.next log with
  | .done outcome => pure (log, .outcome outcome)
  | .ask callId question => pure (log, .question callId question)
  | .sample =>
    let response ← sample (agent.view log)
    run agent workspace sample (log.push (.response response))
  | .act call =>
    let content ← agent.act workspace call
    run agent workspace sample (log.push (.observation call.id content))

end Alaya.Agent
