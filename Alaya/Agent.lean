import Alaya.Model

/-!
The conceptual skeleton of an agent, independent of any provider or environment.

An agent interacts with exactly two stateful worlds — a stochastic model and an environment
that tools act on — so its state is a pair: the **dialogue** (the model's entire memory) and
the **environment** value. Everything an agent does decomposes into three primitives:

- `sample` — the only stochastic step: draw the next assistant turn. Reads only the dialogue.
- `act` — the only effectful step: run one tool call against the environment, returning the
  observation to feed back into the dialogue and the resulting environment.
- `next` — pure control: decide, from the dialogue alone, whether to sample, act, or stop.

Concrete agents (see `Alaya.Agent.MiniSwe`) instantiate these; this module only fixes the types.
-/

namespace Alaya.Agent

open Alaya (Result)

/-- The model's entire memory: the exact context the next `sample` is conditioned on. -/
abbrev Dialogue := Array Chat.Message

/-- Why a run stopped, and what it produced. -/
structure Outcome where
  /-- A short machine-readable status, e.g. "Submitted" or "LimitsExceeded". -/
  status : String
  /-- The agent's final output, when it submitted one. -/
  submission : String := ""
  deriving Repr, BEq, Inhabited

/-- What the loop should do next, decided purely from the dialogue. -/
inductive Directive where
  | sample
  | act (call : Chat.ToolCall)
  | done (outcome : Outcome)
  deriving Inhabited

/-- An agent over an environment type `Env`, given by its three primitive operations. -/
structure Agent (Env : Type) where
  /-- Draw the next assistant turn. Reads only the dialogue. -/
  sample : Dialogue -> Result Chat.Response
  /-- Run one tool call against the environment, returning the observation message to append
  and the resulting environment. -/
  act : Chat.ToolCall -> Env -> Result (Chat.Message × Env)
  /-- Decide the next move from the dialogue alone. Pure and total. -/
  next : Dialogue -> Directive

end Alaya.Agent
