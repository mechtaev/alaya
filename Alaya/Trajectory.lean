import Alaya.Agent
import Alaya.Cas
import Alaya.Cache
import Alaya.Provider
import Alaya.Executor

/-!
A content-addressed **trajectory tree** over any `Alaya.Agent.Agent`, and the operations a CLI
drives it with. See `docs/trajectory-schema.md` for the on-disk format.

Every agent state is a `Log × Cas.Hash`: the events so far and the workspace snapshot. We
persist each state as a `State` object in the same `Cas.Store`, addressed by its own content
hash — so a state is a node whose parent edge, appended events, and workspace are all captured
by one immutable, deduplicating value, exactly like a git commit. A trajectory is therefore a
tree of these nodes; there are no run names or refs in the user's model — states are addressed
by their hashes, copied from `tree`.

The tree is append-only. Growing a continuation from a node (`resume`/`step`) always creates a
*new* child: at a node that already has `n` turn children, sampling asks the persistent cache for
draw index `n`, past the recorded draws, so it replays existing branches deterministically and
can never collide with a sibling. Children a person makes — an `intervention` (`commit`), a
`message` (`tell`), a `reply` — and evaluations do not count as draws.

The trajectory knows nothing about what an agent's tools are or what its observations mean. It
stores events as the agent produced them and shows the model whatever the agent's `view` makes of
them; every rendering here is generic.

Liveness is tracked with the store's refs (`state.<hex>` for each node, `env.<hex>` for each
workspace it points at); `rm` prunes a subtree by rewriting those refs and running `Store.gc`.
-/

namespace Alaya.Trajectory

open Alaya (Result Error Output Executor)
open Alaya.Agent (Agent Event Log Dialogue Outcome Directive View)
open Alaya.Cas (Hash Store)

/-! ## Event serialization

Round-trips events losslessly (including tool-call `arguments`, the raw `invalidArguments?`
string, and a response's reasoning trace), so a reconstructed log is what was recorded and its
view is byte-identical to what the model was sent. -/

private def toolCallToJson (call : Chat.ToolCall) : Lean.Json :=
  .mkObj [
    ("id", call.id), ("name", call.name), ("arguments", call.arguments),
    ("invalid_arguments", call.invalidArguments?.map Lean.Json.str |>.getD .null)]

private def toolCallFromJson (json : Lean.Json) : Except String Chat.ToolCall := do
  let id ← json.getObjVal? "id" >>= Lean.Json.getStr?
  let name ← json.getObjVal? "name" >>= Lean.Json.getStr?
  let arguments ← json.getObjVal? "arguments"
  let invalidArguments? := (json.getObjVal? "invalid_arguments" >>= Lean.Json.getStr?).toOption
  pure { id, name, arguments, invalidArguments? }

private def toolCallsFromJson (json : Lean.Json) : Except String (Array Chat.ToolCall) :=
  match json.getObjVal? "tool_calls" with
  | .ok (.arr calls) => calls.mapM toolCallFromJson
  | _ => pure #[]

def messageToJson : Chat.Message -> Lean.Json
  | .system content => .mkObj [("role", "system"), ("content", content)]
  | .user content => .mkObj [("role", "user"), ("content", content)]
  | .assistant content? toolCalls reasoning? => .mkObj [
      ("role", "assistant"),
      ("content", content?.map Lean.Json.str |>.getD .null),
      ("reasoning", reasoning?.map Lean.Json.str |>.getD .null),
      ("tool_calls", .arr (toolCalls.map toolCallToJson))]
  | .tool callId content => .mkObj [
      ("role", "tool"), ("tool_call_id", callId), ("content", content)]

def messageFromJson (json : Lean.Json) : Except String Chat.Message := do
  match ← json.getObjVal? "role" >>= Lean.Json.getStr? with
  | "system" => .system <$> (json.getObjVal? "content" >>= Lean.Json.getStr?)
  | "user" => .user <$> (json.getObjVal? "content" >>= Lean.Json.getStr?)
  | "assistant" =>
    let content? := (json.getObjVal? "content" >>= Lean.Json.getStr?).toOption
    let calls ← toolCallsFromJson json
    -- Absent in states written before it was recorded, which is exactly `none`.
    let reasoning? := (json.getObjVal? "reasoning" >>= Lean.Json.getStr?).toOption
    pure (.assistant content? calls reasoning?)
  | "tool" =>
    let callId ← json.getObjVal? "tool_call_id" >>= Lean.Json.getStr?
    let content ← json.getObjVal? "content"
    pure (.tool callId content)
  | other => throw s!"unknown message role: {other}"

private def usageToJson (u : Chat.TokenUsage) : Lean.Json :=
  .mkObj [
    ("input", u.input?.map (Lean.Json.num ·) |>.getD .null),
    ("output", u.output?.map (Lean.Json.num ·) |>.getD .null),
    ("total", u.total?.map (Lean.Json.num ·) |>.getD .null)]

private def usageFromJson? (json : Lean.Json) : Option Chat.TokenUsage :=
  match json.getObjVal? "usage" with
  | .ok (.obj _) =>
    let usage := (json.getObjVal? "usage").toOption.get!
    some {
      input? := (usage.getObjVal? "input" >>= Lean.Json.getNat?).toOption
      output? := (usage.getObjVal? "output" >>= Lean.Json.getNat?).toOption
      total? := (usage.getObjVal? "total" >>= Lean.Json.getNat?).toOption }
  | _ => none

/-- A response, as recorded. -/
def responseToJson (r : Chat.Response) : Lean.Json :=
  .mkObj [
    ("content", r.content?.map Lean.Json.str |>.getD .null),
    ("tool_calls", .arr (r.toolCalls.map toolCallToJson)),
    ("reasoning", r.reasoning?.map Lean.Json.str |>.getD .null),
    ("finish_reason", r.finishReason?.map Lean.Json.str |>.getD .null),
    ("usage", r.usage?.map usageToJson |>.getD .null)]

def responseFromJson (json : Lean.Json) : Except String Chat.Response := do
  let content? := (json.getObjVal? "content" >>= Lean.Json.getStr?).toOption
  let toolCalls ← toolCallsFromJson json
  let reasoning? := (json.getObjVal? "reasoning" >>= Lean.Json.getStr?).toOption
  let finishReason? := (json.getObjVal? "finish_reason" >>= Lean.Json.getStr?).toOption
  pure { content?, toolCalls, reasoning?, finishReason?, usage? := usageFromJson? json }

def eventToJson : Event -> Lean.Json
  | .message m => .mkObj [("type", "message"), ("message", messageToJson m)]
  | .response r => .mkObj [("type", "response"), ("response", responseToJson r)]
  | .observation callId content =>
    .mkObj [("type", "observation"), ("call_id", callId), ("content", content)]

def eventFromJson (json : Lean.Json) : Except String Event := do
  match ← json.getObjVal? "type" >>= Lean.Json.getStr? with
  | "message" => .message <$> (json.getObjVal? "message" >>= messageFromJson)
  | "response" => .response <$> (json.getObjVal? "response" >>= responseFromJson)
  | "observation" =>
    let callId ← json.getObjVal? "call_id" >>= Lean.Json.getStr?
    let content ← json.getObjVal? "content"
    pure (.observation callId content)
  | other => throw s!"unknown event type: {other}"

/-! ## State objects -/

/-- What produced a state, for display and provenance. -/
inductive Kind where
  | root
  /-- One model turn: a response and the observations its tool calls produced. -/
  | turn
  /-- A person's workspace change, with the parent's log — plus a notice, when they left one. -/
  | intervention
  /-- A test run against a state, with an overlay the agent never saw. Always a leaf: see
  `Evaluation`. -/
  | evaluation
  /-- A person's message to the agent with no workspace change: see `tell`. -/
  | message
  /-- A turn that ended with the agent asking a person something. The run waits here, and only
  `reply` grows it. -/
  | question
  /-- A person's answer to a `question`, recorded as the tool result of the asking call. -/
  | reply
  deriving BEq, Repr, Inhabited

def Kind.toString : Kind -> String
  | .root => "root"
  | .turn => "turn"
  | .intervention => "intervention"
  | .evaluation => "evaluation"
  | .message => "message"
  | .question => "question"
  | .reply => "reply"

/-- Reads a kind, accepting the names of schema version 1, whose `agent` and `format_error`
turns are both turns here: a format error is a fact about how the agent read the response, not
about the state. -/
def Kind.ofString? : String -> Option Kind
  | "root" => some .root
  | "turn" | "agent" | "format_error" => some .turn
  | "intervention" => some .intervention
  | "evaluation" => some .evaluation
  | "message" => some .message
  | "question" => some .question
  | "reply" => some .reply
  | _ => none

/-- What a person told the agent between turns, and what they changed. Recorded so the notice
the model saw can be re-rendered, and so a report can show the person's words apart from the
envelope. -/
structure Intervention where
  /-- The person's message, verbatim. -/
  message : String
  /-- The workspace changes made alongside it, one `M path` / `+ path` / `- path` line each;
  empty for a message alone. -/
  changed : Array String := #[]
  deriving Inhabited

/-- The notice a person's intervention becomes in the log: a user turn with a fixed envelope,
so the model can tell it from the task and from tool output. -/
def interventionNotice (i : Intervention) : String :=
  let header :=
    if i.changed.isEmpty then "A person sent you a message while you were paused."
    else "A person changed the workspace while you were paused:"
  let changes := String.join (i.changed.toList.map fun line => "\n  " ++ line)
  s!"<intervention>\n{header}{changes}\n{i.message}\n</intervention>"

/-- A question the agent asked a person and is waiting on. `callId` is the asking tool call,
so the eventual answer can be recorded as its result. -/
structure Question where
  callId : String
  text : String
  deriving Inhabited, BEq, Repr

/-- The result of running a test command against a state.

This is a separate axis from `Outcome`, which says how a *run* ended: a submitted run can fail
its tests and a run that hit the step limit can pass them. -/
structure Evaluation where
  command : String
  returncode : Int
  elapsedMs : Nat
  /-- Truncated, so a failing run stays readable in `show`. -/
  output : String
  /-- What was overlaid onto the workspace before the command ran: a directory snapshot, or the
  patch blob. Content-addressed, so the same test set across many trajectories is stored once. -/
  tests? : Option Hash := none
  deriving Inhabited

def Evaluation.passed (evaluation : Evaluation) : Bool := evaluation.returncode == 0

/-- A node of the trajectory tree, content-addressed in the store. `appended` are the events
this state adds to its parent's log (the full log is the concatenation from the root); `env` is
the workspace snapshot after this state's turn. -/
structure State where
  parent? : Option Hash
  env : Hash
  kind : Kind
  /-- Events appended on the edge from the parent to this state. -/
  appended : Log
  /-- The run outcome, when this state ended the run. -/
  outcome? : Option Outcome := none
  /-- Provenance: the model spec that produced this turn, an intervention note, the root task. -/
  note? : Option String := none
  /-- The verdict, on an `evaluation` state. -/
  evaluation? : Option Evaluation := none
  /-- The commit the project started at, inherited from the root, when it was a git checkout.
  Evaluation restores the files a test patch touches to this commit first, so an agent that
  edited the tests cannot decide its own verdict. -/
  baseCommit? : Option String := none
  /-- The pinned container image the commands of this trajectory run in, inherited from the
  parent, or `none` when it runs on the host. Recorded so a continuation runs the same bits the
  earlier turns did — and so a prompt that describes the machine stays true. -/
  image? : Option String := none
  /-- What a person said and changed, on a `message` or `intervention` state that carried a
  message. The notice in `appended` is `interventionNotice` of it. -/
  intervention? : Option Intervention := none
  /-- The open question, on a `question` state. Nothing but `reply` continues from it. -/
  question? : Option Question := none
  deriving Inhabited

namespace State

/-- The tool calls this state's turn made. -/
def calls (state : State) : Array Chat.ToolCall := Agent.Log.calls state.appended

/-- A state a run can be continued from: not ended, not an evaluation, not waiting. -/
def continuable (state : State) : Except String Unit := do
  if state.outcome?.isSome then throw "cannot continue: this state already ended the run"
  if state.kind == .evaluation then
    throw "cannot continue from an evaluation: its workspace holds tests the agent never saw"
  if let some q := state.question? then
    throw s!"this state is waiting for an answer to: {q.text}\nanswer it with `alaya reply HASH TEXT`"

private def evaluationToJson (e : Evaluation) : Lean.Json :=
  .mkObj [
    ("command", e.command), ("returncode", (e.returncode : Lean.Json)),
    ("elapsed_ms", (e.elapsedMs : Lean.Json)), ("output", e.output),
    ("tests", e.tests?.map (Lean.Json.str ·.hex) |>.getD .null)]

private def evaluationFromJson (json : Lean.Json) : Except String Evaluation := do
  let command ← json.getObjVal? "command" >>= Lean.Json.getStr?
  let returncode ← json.getObjVal? "returncode" >>= Lean.Json.getInt?
  let elapsedMs ← json.getObjVal? "elapsed_ms" >>= Lean.Json.getNat?
  let output ← json.getObjVal? "output" >>= Lean.Json.getStr?
  let tests? := (json.getObjVal? "tests" >>= Lean.Json.getStr?).toOption.map (⟨·⟩)
  pure { command, returncode, elapsedMs, output, tests? }

private def outcomeToJson (o : Outcome) : Lean.Json :=
  .mkObj [("status", o.status), ("submission", o.submission)]

private def outcomeFromJson (json : Lean.Json) : Except String Outcome := do
  let status ← json.getObjVal? "status" >>= Lean.Json.getStr?
  let submission ← json.getObjVal? "submission" >>= Lean.Json.getStr?
  pure { status, submission }

/-- The current schema version. Version 1 stored rendered messages in `appended`; version 2
stores events. -/
def schemaVersion : Nat := 2

def toJson (state : State) : Lean.Json :=
  .mkObj [
    ("v", (schemaVersion : Lean.Json)),
    ("parent", state.parent?.map (Lean.Json.str ·.hex) |>.getD .null),
    ("env", state.env.hex),
    ("kind", state.kind.toString),
    ("appended", .arr (state.appended.map eventToJson)),
    ("outcome", state.outcome?.map outcomeToJson |>.getD .null),
    ("note", state.note?.map Lean.Json.str |>.getD .null),
    ("image", state.image?.map Lean.Json.str |>.getD .null),
    ("base_commit", state.baseCommit?.map Lean.Json.str |>.getD .null),
    ("evaluation", state.evaluation?.map evaluationToJson |>.getD .null),
    ("intervention", state.intervention?.map (fun i => .mkObj [
      ("message", i.message), ("changed", .arr (i.changed.map Lean.Json.str))]) |>.getD .null),
    ("question", state.question?.map (fun q => .mkObj [
      ("call_id", q.callId), ("text", q.text)]) |>.getD .null)]

/-- Reads a state of any schema version. A version-1 `appended` holds rendered messages, whose
raw events were never recorded; each is lifted to `Event.message`, which a view passes through
unchanged, so an old forest stays readable and can still grow. -/
def fromJson (json : Lean.Json) : Except String State := do
  let version := (json.getObjVal? "v" >>= Lean.Json.getNat?).toOption.getD 1
  let parent? := (json.getObjVal? "parent" >>= Lean.Json.getStr?).toOption.map (⟨·⟩)
  let env : Hash := ⟨← json.getObjVal? "env" >>= Lean.Json.getStr?⟩
  let kind ← match Kind.ofString? (← json.getObjVal? "kind" >>= Lean.Json.getStr?) with
    | some kind => pure kind
    | none => throw "unknown state kind"
  let items ← json.getObjVal? "appended" >>= Lean.Json.getArr?
  let appended ← if version == 1
    then items.mapM fun item => Event.message <$> messageFromJson item
    else items.mapM eventFromJson
  let outcome? ← match json.getObjVal? "outcome" with
    | .ok .null => pure none
    | .ok o => some <$> outcomeFromJson o
    | .error _ => pure none
  let note? := (json.getObjVal? "note" >>= Lean.Json.getStr?).toOption
  let image? := (json.getObjVal? "image" >>= Lean.Json.getStr?).toOption
  let baseCommit? := (json.getObjVal? "base_commit" >>= Lean.Json.getStr?).toOption
  let evaluation? ← match json.getObjVal? "evaluation" with
    | .ok .null => pure none
    | .ok e => some <$> evaluationFromJson e
    | .error _ => pure none
  let intervention? ← match json.getObjVal? "intervention" with
    | .ok (.obj _) =>
      let i := (json.getObjVal? "intervention").toOption.get!
      let message ← i.getObjVal? "message" >>= Lean.Json.getStr?
      let changed ← (← i.getObjVal? "changed" >>= Lean.Json.getArr?).mapM Lean.Json.getStr?
      pure (some ({ message, changed } : Intervention))
    | _ => pure none
  let question? ← match json.getObjVal? "question" with
    | .ok (.obj _) =>
      let q := (json.getObjVal? "question").toOption.get!
      let callId ← q.getObjVal? "call_id" >>= Lean.Json.getStr?
      let text ← q.getObjVal? "text" >>= Lean.Json.getStr?
      pure (some ({ callId, text } : Question))
    | _ => pure none
  pure { parent?, env, kind, appended, outcome?, note?, image?, baseCommit?, evaluation?
         intervention?, question? }

end State

/-! ## The store as a trajectory tree

Each state is a store blob addressed by its own content; two refs record liveness so `Store.gc`
preserves exactly the reachable nodes and workspaces: `state.<hex>` pins the node blob and
`env.<hex>` pins its workspace tree. -/

private def stateRef (h : Hash) : String := "state." ++ h.hex
private def envRef (h : Hash) : String := "env." ++ h.hex

/-- Persists a state, returning its content hash, and pins its liveness refs. -/
def putState (store : Store) (state : State) : Result Hash := do
  let hash ← store.putBytes state.toJson.compress.toUTF8
  store.setRef (stateRef hash) hash
  store.setRef (envRef state.env) state.env
  pure hash

/-- Loads the state at `hash`. -/
def getState (store : Store) (hash : Hash) : Result State := do
  match ← store.getBytes hash with
  | none => throw <| .storage s!"no such state: {hash.hex}"
  | some bytes =>
    let text ← match String.fromUTF8? bytes with
      | some text => pure text
      | none => throw <| .storage s!"corrupt state blob: {hash.hex}"
    let json ← Result.fromExcept Error.storage (Lean.Json.parse text)
    Result.fromExcept Error.storage (State.fromJson json)

/-- Every state hash in the store, from the liveness refs. -/
def allStates (store : Store) : Result (Array Hash) := do
  let refs ← store.listRefs
  pure <| refs.filterMap fun (name, hash) =>
    if name.startsWith "state." then some hash else none

/-- The children of `hash`, in ref-listing (hash) order. -/
def children (store : Store) (hash : Hash) : Result (Array Hash) := do
  let states ← allStates store
  states.filterMapM fun candidate => do
    let state ← getState store candidate
    pure <| if state.parent? == some hash then some candidate else none

/-- Resolves a (possibly abbreviated) hex prefix to the unique state it names. -/
def resolve (store : Store) (pfx : String) : Result Hash := do
  let states ← allStates store
  let hits := states.filter (·.hex.startsWith pfx)
  match hits.toList with
  | [hash] => pure hash
  | [] => throw <| .configuration s!"no state matches {pfx}"
  | _ => throw <| .configuration s!"ambiguous state prefix {pfx} ({hits.size} matches)"

/-- Reconstructs the full log at `hash` by concatenating appended events root→node. -/
partial def logOf (store : Store) (hash : Hash) : Result Log := do
  let state ← getState store hash
  let ancestors ← match state.parent? with
    | some parent => logOf store parent
    | none => pure #[]
  pure (ancestors ++ state.appended)

/-- The transitive subtree rooted at `hash` (inclusive). -/
partial def subtree (store : Store) (hash : Hash) : Result (Array Hash) := do
  let kids ← children store hash
  let mut acc := #[hash]
  for kid in kids do
    acc := acc ++ (← subtree store kid)
  pure acc

/-- Deletes a state and its whole subtree, then reclaims every blob no longer reachable from a
surviving state or its workspace. -/
def removeSubtree (store : Store) (hash : Hash) : Result Nat := do
  let doomed ← subtree store hash
  -- Drop the doomed states' refs; then re-pin env refs from the survivors only, so a workspace
  -- shared with a survivor stays live while one used only by the subtree is freed.
  for h in doomed do
    store.deleteRef (stateRef h)
  let refs ← store.listRefs
  for (name, _) in refs do
    if name.startsWith "env." then store.deleteRef name
  let survivors := (← allStates store)
  for s in survivors do
    let state ← getState store s
    store.setRef (envRef state.env) state.env
  let _ ← store.gc
  pure doomed.size

/-! ## Model construction -/

/-- Builds the model stack behind a `provider:name` spec, wrapping it with retry, batching, and
the persistent cache that makes replay and forking deterministic. -/
def buildModel (spec : String) (temperature : Float) (cacheDir : System.FilePath)
    (options : Provider.Options := {}) : Result Model := do
  let base ← Provider.fromSpec spec temperature options
  -- Transport failures (a timeout, a dropped connection) are retried here, though the library
  -- default is not to: the worry there is a request the provider processed before the line
  -- died, and for a sampling that only costs a duplicate request. Not retrying costs more — the
  -- run aborts, and resuming it starts a fresh container, so anything the agent kept outside
  -- the workspace (`/tmp` scripts, installed packages) is gone when it continues.
  let model ← base.retry { retryUnknownDelivery := true }
  let model ← model.batch .sequential
  Cache.persistent model { directory := cacheDir }

/-! ## Driving the agent, recording each turn as a state -/

/-- The live run: the store holding every durable artefact, the working directory holding
none, the executor that runs commands in it, the model, and the agent being driven. -/
structure Runtime where
  /-- Where everything durable lives. -/
  store : Store
  /-- Where the agent acts. Wiped and re-materialized from a snapshot at every checkout, so
  nothing here survives a turn that is not first captured into `store`. -/
  workDir : System.FilePath
  /-- Where shell commands run: the agent's, and an evaluation's test command. -/
  executor : Executor
  model : Model
  agent : Agent

/-- Why a turn handed control back to the driver. -/
inductive Halt where
  /-- The turn went normally; the run goes on. -/
  | continue
  /-- The turn ended the run. -/
  | outcome (outcome : Outcome)
  /-- The turn asked a person something; the run waits for `reply`. -/
  | question (question : Question)
  deriving Inhabited

/-- Follows the agent's directives after a sample until it wants to sample again or stops,
recording each observation and snapshotting the workspace after each act. Returns the events
appended, the final workspace, and why it stopped. -/
private partial def follow (rt : Runtime) (log : Log) (appended : Log) (env : Hash) :
    Result (Log × Hash × Option Question × Halt) := do
  match rt.agent.next log with
  | .sample => pure (appended, env, none, .continue)
  | .done outcome => pure (appended, env, none, .outcome outcome)
  | .suspend call text =>
    let question : Question := { callId := call.id, text }
    pure (appended, env, some question, .question question)
  | .act call =>
    let content ← rt.agent.act call
    let env ← rt.store.snapshot rt.workDir
    let event := Event.observation call.id content
    follow rt (log.push event) (appended.push event) env

/-- Runs one model turn from `parent` (whose log is `log` and workspace is `env`, already
materialized into `rt.workDir`), records the turn as a new child state, and returns the child,
its log, its workspace, and why the turn stopped, if it did.

Sampling asks for draw index `= turn children of parent`, replaying recorded branches and
appending exactly one new draw — so a new continuation is always a fresh sibling, and an
interrupted run resumes deterministically from its cache. -/
def advance (rt : Runtime) (note : String) (parent : Hash) (log : Log) (env : Hash) :
    Result (Hash × Log × Hash × Halt) := do
  -- Only children that came from sampling consume a draw: an evaluation, an intervention, a
  -- message, or a reply is recorded against a state without asking the model anything, and
  -- counting it would push the next continuation past a draw the cache holds.
  let mut childCount := 0
  for child in ← children rt.store parent do
    let kind := (← getState rt.store child).kind
    if kind == .turn || kind == .question then childCount := childCount + 1
  -- Children run in whatever the parent ran in; the image and base commit are properties of
  -- the trajectory.
  let parentState ← getState rt.store parent
  let (image?, baseCommit?) := (parentState.image?, parentState.baseCommit?)
  let stream ← rt.model.sample { messages := rt.agent.view log, tools := rt.agent.tools }
  let responses ← stream.nextN (childCount + 1)
  let response ← match responses[childCount]? with
    | some response => pure response
    | none => throw <| .protocol "model returned too few responses"
  let event := Event.response response
  let (appended, env, question?, halt) ← follow rt (log.push event) #[event] env
  let outcome? := match halt with | .outcome o => some o | _ => none
  let child ← putState rt.store {
    parent? := some parent, env, appended, outcome?, question?
    kind := if question?.isSome then .question else .turn
    note? := some note, image?, baseCommit? }
  pure (child, log ++ appended, env, halt)

/-- Materializes `env` into `rt.workDir`, replacing whatever is there.

The work directory is modified after every checkout — by the commands of the run, and by the
overlay an evaluation applies — so `MaterializeConfig.verify`, on by default, is what keeps this
sound: without re-capturing the directory first, an incremental materialize would trust a stale
record and leave everything those writes added, so a fork would start from the abandoned
branch's files and a turn after an evaluation would start from the hidden tests. -/
private def checkoutInto (rt : Runtime) (env : Hash) : Result Unit :=
  rt.store.materialize env rt.workDir { onExisting := .replace }

/-- Advances exactly one model turn from `hash`, returning the new child state. -/
def stepOnce (rt : Runtime) (note : String) (hash : Hash) : Result Hash := do
  let state ← getState rt.store hash
  Result.fromExcept Error.configuration state.continuable
  checkoutInto rt state.env
  let (child, _, _, _) ← advance rt note hash (← logOf rt.store hash) state.env
  pure child

/-- Grows a continuation from `hash` until the run ends or stops at a question, returning the
state it stopped at. -/
partial def resume (rt : Runtime) (note : String) (hash : Hash)
    (onStep : Hash -> Result Unit) : Result Hash := do
  let start ← getState rt.store hash
  Result.fromExcept Error.configuration start.continuable
  checkoutInto rt start.env
  let rec go (parent : Hash) (log : Log) (env : Hash) : Result Hash := do
    let (child, log, env, halt) ← advance rt note parent log env
    onStep child
    match halt with
    | .continue => go child log env
    | _ => pure child
  go hash (← logOf rt.store hash) start.env

/-! ## Evaluation

Running tests against a state is deliberately not part of the run: the tests are an overlay the
agent never saw, and letting them into a state it could continue from would both contaminate the
trajectory and, for a benchmark, invalidate the measurement. So an evaluation is a leaf child
whose workspace is the agent's plus the overlay, and `resume`/`step`/`commit` refuse it. -/

/-- What to overlay onto a state's workspace before the test command runs. Both forms are
authoritative: what they carry replaces what the agent left, so an agent that weakened a test
cannot decide its own verdict. -/
inductive Overlay where
  | nothing
  /-- A host directory whose contents are copied over the workspace. -/
  | directory (path : System.FilePath)
  /-- A unified diff. The files it touches are first restored to the trajectory's base commit
  (or deleted, when they did not exist there), so it applies to pristine content. -/
  | patch (contents : String)

/-- The paths a unified diff touches, read from its `+++` lines. -/
def patchPaths (patch : String) : Array String := Id.run do
  let mut paths := #[]
  for line in patch.splitOn "\n" do
    if line.startsWith "+++ " then
      let target := ((line.drop 4).toString.splitOn "\t").headD ""
      let target := target.trimAscii.toString
      let target := if target.startsWith "b/" then (target.drop 2).toString else target
      if target != "/dev/null" && !target.isEmpty && !paths.contains target then
        paths := paths.push target
  paths

/-- Single-quotes a path for `/bin/sh`. -/
private def shellQuote (s : String) : String :=
  "'" ++ s.replace "'" "'\\''" ++ "'"

/-- The overlay's content address, so an evaluation records exactly what was applied and the
same test set shared by many trajectories is stored once. -/
private def overlayHash (store : Store) : Overlay -> Result (Option Hash)
  | .nothing => pure none
  | .directory path => some <$> store.snapshot path
  | .patch contents => some <$> store.putBytes contents.toUTF8

/-- The name the patch is written under inside the workspace; removed before the snapshot, so it
never becomes part of the evaluated tree. -/
private def patchFile : String := ".alaya-test.patch"

/-- Runs a shell command in the work directory through the runtime's executor. -/
private def execBash (rt : Runtime) (command : String) : Result Output :=
  Result.fromIO Error.storage (rt.executor.bash rt.workDir command)

private def applyOverlay (rt : Runtime) (state : State) : Overlay -> Result Unit
  | .nothing => pure ()
  | .directory path => do
    let source ← Result.fromIO Error.storage (IO.FS.realPath path)
    let copy ← Result.fromIO Error.storage (IO.Process.output {
      cmd := "cp", args := #["-R", s!"{source}/.", rt.workDir.toString] })
    if copy.exitCode != 0 then
      throw <| .storage s!"cannot overlay {source}: {copy.stderr}"
  | .patch contents => do
    let paths := patchPaths contents
    if paths.isEmpty then throw <| .configuration "the test patch touches no files"
    -- Restore what the patch touches to the base commit, so the agent's edits to the tests
    -- cannot survive; a path that did not exist at the base commit is removed instead.
    if let some base := state.baseCommit? then
      let quoted := " ".intercalate (paths.map shellQuote).toList
      let reset ← execBash rt
        s!"for p in {quoted}; do git checkout {base} -- \"$p\" 2>/dev/null || rm -f \"$p\"; done"
      if reset.returncode != 0 then
        throw <| .configuration s!"restoring test files to {base} failed: {reset.output}"
    Result.fromIO Error.storage (IO.FS.writeFile (rt.workDir / patchFile) contents)
    let applied ← execBash rt s!"git apply -v {patchFile}"
    Result.fromIO Error.storage (IO.FS.removeFile (rt.workDir / patchFile))
    if applied.returncode != 0 then
      throw <| .configuration s!"applying the test patch failed: {applied.output}"

/-- Keeps a test run readable in `show` without putting megabytes in a state blob. -/
private def truncateOutput (s : String) : String :=
  if s.length <= 20000 then s
  else
    let elided := s.length - 20000
    String.ofList (s.toList.take 10000) ++ s!"\n… {elided} characters elided …\n" ++
      String.ofList (s.toList.drop (s.length - 10000))

/-- An evaluation of `hash` that already ran this command against this overlay. -/
def evaluationOf? (store : Store) (hash : Hash) (command : String) (tests? : Option Hash) :
    Result (Option Hash) := do
  for child in ← children store hash do
    let state ← getState store child
    if state.kind == .evaluation then
      if let some e := state.evaluation? then
        if e.command == command && e.tests? == tests? then return some child
  pure none

/-- Runs `command` against `hash`'s workspace with `overlay` applied, and records the verdict as
a leaf child. The command runs wherever the trajectory runs — in its pinned container, if it has
one — under the executor's timeout, which a caller should set far higher than an agent's
per-command limit. Re-evaluating the same state, command, and overlay returns the existing node
unless `force`. -/
def evaluate (rt : Runtime) (hash : Hash) (command : String) (overlay : Overlay)
    (force : Bool := false) : Result Hash := do
  let state ← getState rt.store hash
  if state.kind == .evaluation then
    throw <| .configuration "cannot evaluate an evaluation: it is already a leaf"
  let tests? ← overlayHash rt.store overlay
  if !force then
    if let some existing ← evaluationOf? rt.store hash command tests? then return existing
  checkoutInto rt state.env
  applyOverlay rt state overlay
  let started ← Result.fromIO Error.storage IO.monoMsNow
  let output ← execBash rt command
  let elapsedMs := (← Result.fromIO Error.storage IO.monoMsNow) - started
  let env ← rt.store.snapshot rt.workDir
  putState rt.store {
    parent? := some hash, env, kind := .evaluation, appended := #[]
    image? := state.image?, baseCommit? := state.baseCommit?
    evaluation? := some {
      command, returncode := output.returncode, elapsedMs
      output := truncateOutput (output.output ++
        (if output.exceptionInfo.isEmpty then "" else s!"\n{output.exceptionInfo}"))
      tests? } }

/-! ## Root creation and what a person adds -/

/-- Creates a root state from the initial project directory: the agent's opening log — its
prompts — and a snapshot of `project`. -/
def createRoot (store : Store) (log : Log) (project : System.FilePath)
    (note? : Option String := none) (image? : Option String := none)
    (baseCommit? : Option String := none) : Result Hash := do
  let env ← store.snapshot project
  putState store { parent? := none, env, kind := .root, appended := log, note?, image?, baseCommit? }

/-- A state a person may build on: anything but an evaluation, whose workspace holds tests the
agent never saw, or a state waiting for an answer, which `reply` alone grows. An ended run is
fine — fixing something after a submission and continuing from there is what interventions are
for. -/
private def buildable (state : State) : Result Unit := do
  if state.kind == .evaluation then
    throw <| .configuration
      "cannot build on an evaluation: its workspace holds tests the agent never saw"
  if let some q := state.question? then
    throw <| .configuration
      s!"this state is waiting for an answer to: {q.text}\nanswer it with `alaya reply HASH TEXT`"

/-- The workspace changes from `before` to `after`, one line each. -/
private def changedLines (store : Store) (before after : Hash) : Result (Array String) := do
  let changes ← store.diff before after
  pure <| changes.map fun
    | .added path _ _ => s!"+ {path}"
    | .removed path _ => s!"- {path}"
    | .modified path _ _ => s!"M {path}"

/-- Records a hand-edited workspace `dir` as an intervention child of `hash`: new workspace
snapshot, and the parent's log — plus, with `tell?`, a notice to the model saying what was said
and which paths changed. Without it the model learns of the change only by running commands. -/
def commit (store : Store) (hash : Hash) (dir : System.FilePath) (note? : Option String)
    (tell? : Option String := none) : Result Hash := do
  let parent ← getState store hash
  buildable parent
  let env ← store.snapshot dir
  let intervention? ← match tell? with
    | none => pure none
    | some message =>
      pure (some ({ message, changed := ← changedLines store parent.env env } : Intervention))
  putState store {
    parent? := some hash, env, kind := .intervention, note?
    appended := intervention?.map (fun i => #[Event.message (.user (interventionNotice i))])
      |>.getD #[]
    intervention?, image? := parent.image?, baseCommit? := parent.baseCommit? }

/-- Records a person's message to the agent as a child of `hash`: same workspace, and the log
grown by one user turn carrying the message in the intervention envelope. -/
def tell (store : Store) (hash : Hash) (message : String) : Result Hash := do
  let parent ← getState store hash
  buildable parent
  let intervention : Intervention := { message }
  putState store {
    parent? := some hash, env := parent.env, kind := .message
    appended := #[.message (.user (interventionNotice intervention))]
    intervention? := some intervention
    image? := parent.image?, baseCommit? := parent.baseCommit? }

/-- Answers the question `hash` is waiting on: a child with the same workspace whose one appended
event is the observation of the asking call, carrying `text` verbatim. Answering the same
question again makes a sibling — a fork on the answer. -/
def reply (store : Store) (hash : Hash) (text : String) : Result Hash := do
  let parent ← getState store hash
  let question ← match parent.question? with
    | some q => pure q
    | none => throw <| .configuration "this state is not waiting for an answer"
  putState store {
    parent? := some hash, env := parent.env, kind := .reply
    appended := #[.observation question.callId (.str text)]
    image? := parent.image?, baseCommit? := parent.baseCommit? }

/-- Every question in the forest that has not been answered: waiting states without a `reply`
child. -/
def waiting (store : Store) : Result (Array (Hash × Question)) := do
  let states ← allStates store
  states.filterMapM fun hash => do
    let state ← getState store hash
    match state.question? with
    | none => pure none
    | some q =>
      let kids ← children store hash
      let answered ← kids.anyM fun kid => do pure ((← getState store kid).kind == .reply)
      pure (if answered then none else some (hash, q))

/-! ## Rendering

Everything here is generic: a tool call is shown by name and arguments, an observation by its
content. What a call *means* is the agent's business. -/

private def take (s : String) (n : Nat) : String := String.ofList (s.toList.take n)

private def short (h : Hash) : String := take h.hex 12

private def flatten (s : String) (limit : Nat := 60) : String :=
  let flat := (s.replace "\n" " ").replace "\r" " "
  if flat.length > limit then take flat (limit - 3) ++ "..." else flat

/-- The arguments of a call as one string: the value, when the arguments are a single string
field — the common shape of a command tool — otherwise the compact JSON, or the raw text when
it did not parse. -/
def argumentsSummary (call : Chat.ToolCall) : String :=
  match call.invalidArguments? with
  | some raw => raw
  | none =>
    match call.arguments with
    | .obj fields =>
      match fields.foldl (fun (acc : Array (String × Lean.Json)) k v => acc.push (k, v)) #[] with
      | #[(_, Lean.Json.str value)] => value
      | _ => call.arguments.compress
    | other => other.compress

/-- `name  arguments`, flattened to one line. -/
def callSummary (call : Chat.ToolCall) : String :=
  call.name ++ "  " ++ flatten (argumentsSummary call)

private def observationText : Lean.Json -> String
  | .str s => s
  | other => other.pretty

private def label (state : State) : String :=
  match state.kind with
  | .root => "root  " ++ flatten (state.note?.getD "")
  | .turn | .question =>
    let calls := state.calls
    let first := match calls[0]? with
      | some call => callSummary call
      | none => "turn  (no tool call)"
    let more := if calls.size > 1 then s!"  (+{calls.size - 1})" else ""
    first ++ more
  | .intervention => "commit  " ++ (state.note?.getD "")
  | .message => "tell  " ++ flatten (state.intervention?.map (·.message) |>.getD "")
  | .reply =>
    let text := match state.appended[0]? with
      | some (Event.observation _ (Lean.Json.str s)) => s
      | some (Event.observation _ other) => other.compress
      | _ => ""
    "reply  " ++ flatten text
  | .evaluation =>
    match state.evaluation? with
    | some e =>
      let verdict := if e.passed then "pass" else s!"fail {e.returncode}"
      s!"eval  [{verdict}]  " ++ flatten e.command
    | none => "eval"

private def outcomeSuffix (state : State) : String :=
  match state.outcome? with
  | some o => s!"  [{o.status}]"
  | none => ""

/-- Renders the whole forest as indented lines, each `<short-hash> <label> [outcome]`. -/
partial def treeLines (store : Store) : Result (Array String) := do
  let states ← allStates store
  let mut roots := #[]
  for h in states do
    if (← getState store h).parent? == none then roots := roots.push h
  let rec render (hash : Hash) (depth : Nat) : Result (Array String) := do
    let state ← getState store hash
    let kids ← children store hash
    let indent := String.join (List.replicate depth "  ")
    -- A question is waiting until some child answers it.
    let mut waitingMark := ""
    if state.question?.isSome then
      let answered ← kids.anyM fun kid => do pure ((← getState store kid).kind == .reply)
      if !answered then waitingMark := "  [Waiting]"
    let line := s!"{indent}{short hash}  {label state}{outcomeSuffix state}{waitingMark}"
    let mut lines := #[line]
    for kid in kids do
      lines := lines ++ (← render kid (depth + 1))
    pure lines
  let mut lines := #[]
  for root in roots do
    lines := lines ++ (← render root 0)
  pure lines

/-- One event as lines: who, then what. -/
private def eventLines : Event -> Array String
  | .message m =>
    match m with
    | .system c => #["[system]", c]
    | .user c => #["[user]", c]
    | .assistant c? calls _ =>
      #["[assistant]", c?.getD ""] ++ calls.map fun call => "[call] " ++ callSummary call
    | .tool id content => #[s!"[tool {id}]", observationText content]
  | .response r =>
    #["[response]", r.content?.getD ""] ++ r.toolCalls.map fun call => "[call] " ++ callSummary call
  | .observation id content => #[s!"[observation {id}]", observationText content]

/-- Renders a state for `show`: metadata, then the full reconstructed log — what happened — and,
given the agent's view, the context the model would be sent from here — what it sees. -/
def showLines (store : Store) (hash : Hash) (view? : Option View := none) :
    Result (Array String) := do
  let state ← getState store hash
  let log ← logOf store hash
  let mut lines := #[
    s!"state    {hash.hex}",
    s!"kind     {state.kind.toString}",
    s!"parent   {state.parent?.map (·.hex) |>.getD "(root)"}",
    s!"env      {state.env.hex}"]
  if let some note := state.note? then lines := lines.push s!"note     {note}"
  if let some image := state.image? then lines := lines.push s!"image    {image}"
  if let some base := state.baseCommit? then lines := lines.push s!"base     {base}"
  if let some e := state.evaluation? then
    lines := lines.push s!"command  {e.command}"
    lines := lines.push s!"verdict  {if e.passed then "pass" else "fail"} (rc={e.returncode}, {e.elapsedMs} ms)"
    if let some tests := e.tests? then lines := lines.push s!"tests    {tests.hex}"
    lines := lines.push "--- test output ---"
    lines := lines.push e.output
  if let some o := state.outcome? then
    lines := lines.push s!"outcome  {o.status}"
    if o.submission != "" then lines := lines.push s!"submission:\n{o.submission}"
  if let some q := state.question? then lines := lines.push s!"question {q.text}"
  if let some i := state.intervention? then lines := lines.push s!"message  {i.message}"
  lines := lines.push "--- log ---"
  for event in log do
    lines := lines ++ eventLines event
  if let some view := view? then
    lines := lines.push "--- view: the context sent from this state ---"
    for message in view log do
      lines := lines ++ eventLines (.message message)
  pure lines

/-- The workspace changes from `a`'s snapshot to `b`'s. -/
def diffLines (store : Store) (a b : Hash) : Result (Array String) := do
  let sa ← getState store a
  let sb ← getState store b
  changedLines store sa.env sb.env

end Alaya.Trajectory
