import Alaya.Agent
import Alaya.Cas
import Alaya.Cache
import Alaya.Provider
import Alaya.Executor

/-! A content-addressed trajectory tree over any `Alaya.Agent.Agent`, and the operations the
command line drives it with. See `docs/trajectory-schema.md`. -/

namespace Alaya.Trajectory

open Alaya (Result Error Output Executor)
open Alaya.Agent (Agent Event Log Dialogue Outcome Directive View)
open Alaya.Cas (Hash Store)

/-! ## Event serialization -/

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
  /-- A grader's verdict on a state, with the checkout as the grader left it; always a leaf. -/
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

def Kind.ofString? : String -> Option Kind
  | "root" => some .root
  | "turn" => some .turn
  | "intervention" => some .intervention
  | "evaluation" => some .evaluation
  | "message" => some .message
  | "question" => some .question
  | "reply" => some .reply
  | _ => none

/-- What a person told the agent between turns, and what they changed. -/
structure Intervention where
  /-- The person's message, verbatim. -/
  message : String
  /-- The workspace changes made alongside it, one `M path` / `+ path` / `- path` line each;
  empty for a message alone. -/
  changed : Array String := #[]
  deriving Inhabited

/-- The user turn an intervention becomes in the log. -/
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

/-- A grader's verdict on a state. A separate axis from `Outcome`, which says how a *run*
ended: a submitted run can fail its grader and a run that hit the step limit can pass it. -/
structure Evaluation where
  /-- The grader command as given, with its `{checkout}` and `{out}` placeholders unexpanded. -/
  grader : String
  returncode : Int
  elapsedMs : Nat
  /-- The grader's stdout and stderr, merged and truncated, so a failing run stays readable. -/
  output : String
  /-- A snapshot of the grader's output directory — reports, logs, whatever it wrote to `{out}` —
  or `none` when it wrote nothing. -/
  evidence? : Option Hash := none
  /-- The grader's `{out}/verdict.json`, when it wrote one. -/
  summary? : Option Lean.Json := none
  deriving Inhabited

/-- Whether the state passed: the grader's own `passed` when its summary has one, otherwise a
zero exit status. -/
def Evaluation.passed (evaluation : Evaluation) : Bool :=
  match evaluation.summary?.bind fun s => (s.getObjVal? "passed" >>= Lean.Json.getBool?).toOption with
  | some verdict => verdict
  | none => evaluation.returncode == 0

/-- How many of the grader's checks passed, out of how many: the summary's
`score: {passed, total}`, when it has one. -/
def Evaluation.score? (evaluation : Evaluation) : Option (Nat × Nat) := do
  let score ← (← evaluation.summary?).getObjVal? "score" |>.toOption
  let passed ← (score.getObjVal? "passed" >>= Lean.Json.getNat?).toOption
  let total ← (score.getObjVal? "total" >>= Lean.Json.getNat?).toOption
  pure (passed, total)

/-- `pass` or `fail`, with the exit status of a failure and the score when there is one. -/
def Evaluation.verdict (evaluation : Evaluation) : String :=
  let base := if evaluation.passed then "pass" else s!"fail {evaluation.returncode}"
  match evaluation.score? with
  | some (passed, total) => s!"{base} {passed}/{total}"
  | none => base

/-- A node of the trajectory tree, content-addressed in the store. -/
structure State where
  parent? : Option Hash
  workspace : Hash
  kind : Kind
  /-- Events appended on the edge from the parent to this state. -/
  appended : Log
  /-- The run outcome, when this state ended the run. -/
  outcome? : Option Outcome := none
  /-- Provenance: the model spec that produced this turn, an intervention note, the root task. -/
  note? : Option String := none
  /-- The verdict, on an `evaluation` state. -/
  evaluation? : Option Evaluation := none
  /-- The pinned container image, inherited from the root; `none` on the host. -/
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
    throw "cannot continue from an evaluation: it is a verdict on its parent, not a point in the run"
  if let some q := state.question? then
    throw s!"this state is waiting for an answer to: {q.text}\nanswer it with `alaya reply HASH TEXT`"

private def evaluationToJson (e : Evaluation) : Lean.Json :=
  .mkObj [
    ("grader", e.grader), ("returncode", (e.returncode : Lean.Json)),
    ("elapsed_ms", (e.elapsedMs : Lean.Json)), ("output", e.output),
    ("evidence", e.evidence?.map (Lean.Json.str ·.hex) |>.getD .null),
    ("summary", e.summary?.getD .null)]

private def evaluationFromJson (json : Lean.Json) : Except String Evaluation := do
  let grader ← json.getObjVal? "grader" >>= Lean.Json.getStr?
  let returncode ← json.getObjVal? "returncode" >>= Lean.Json.getInt?
  let elapsedMs ← json.getObjVal? "elapsed_ms" >>= Lean.Json.getNat?
  let output ← json.getObjVal? "output" >>= Lean.Json.getStr?
  let evidence? := (json.getObjVal? "evidence" >>= Lean.Json.getStr?).toOption.map (⟨·⟩)
  let summary? := match json.getObjVal? "summary" with
    | .ok .null | .error _ => none
    | .ok v => some v
  pure { grader, returncode, elapsedMs, output, evidence?, summary? }

private def outcomeToJson (o : Outcome) : Lean.Json :=
  .mkObj [("status", o.status), ("submission", o.submission)]

private def outcomeFromJson (json : Lean.Json) : Except String Outcome := do
  let status ← json.getObjVal? "status" >>= Lean.Json.getStr?
  let submission ← json.getObjVal? "submission" >>= Lean.Json.getStr?
  pure { status, submission }

/-- The schema version written in every state object, so a reader can refuse what it does not
understand. -/
def schemaVersion : Nat := 1

def toJson (state : State) : Lean.Json :=
  .mkObj [
    ("v", (schemaVersion : Lean.Json)),
    ("parent", state.parent?.map (Lean.Json.str ·.hex) |>.getD .null),
    ("workspace", state.workspace.hex),
    ("kind", state.kind.toString),
    ("appended", .arr (state.appended.map eventToJson)),
    ("outcome", state.outcome?.map outcomeToJson |>.getD .null),
    ("note", state.note?.map Lean.Json.str |>.getD .null),
    ("image", state.image?.map Lean.Json.str |>.getD .null),
    ("evaluation", state.evaluation?.map evaluationToJson |>.getD .null),
    ("intervention", state.intervention?.map (fun i => .mkObj [
      ("message", i.message), ("changed", .arr (i.changed.map Lean.Json.str))]) |>.getD .null),
    ("question", state.question?.map (fun q => .mkObj [
      ("call_id", q.callId), ("text", q.text)]) |>.getD .null)]

def fromJson (json : Lean.Json) : Except String State := do
  let version ← json.getObjVal? "v" >>= Lean.Json.getNat?
  if version != schemaVersion then
    throw s!"state object has schema version {version}; this build reads version {schemaVersion}"
  let parent? := (json.getObjVal? "parent" >>= Lean.Json.getStr?).toOption.map (⟨·⟩)
  let workspace : Hash := ⟨← json.getObjVal? "workspace" >>= Lean.Json.getStr?⟩
  let kind ← match Kind.ofString? (← json.getObjVal? "kind" >>= Lean.Json.getStr?) with
    | some kind => pure kind
    | none => throw "unknown state kind"
  let appended ← (← json.getObjVal? "appended" >>= Lean.Json.getArr?).mapM eventFromJson
  let outcome? ← match json.getObjVal? "outcome" with
    | .ok .null => pure none
    | .ok o => some <$> outcomeFromJson o
    | .error _ => pure none
  let note? := (json.getObjVal? "note" >>= Lean.Json.getStr?).toOption
  let image? := (json.getObjVal? "image" >>= Lean.Json.getStr?).toOption
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
  pure { parent?, workspace, kind, appended, outcome?, note?, image?, evaluation?
         intervention?, question? }

end State

/-! ## The store as a trajectory tree -/

private def stateRef (h : Hash) : String := "state." ++ h.hex
private def workspaceRef (h : Hash) : String := "workspace." ++ h.hex

/-- The trees a state keeps alive: its workspace, and an evaluation's evidence. -/
private def treesOf (state : State) : Array Hash :=
  #[state.workspace] ++ (state.evaluation?.bind (·.evidence?)).toArray

/-- Persists a state, returning its content hash, and pins its liveness refs. -/
def putState (store : Store) (state : State) : Result Hash := do
  let hash ← store.putBytes state.toJson.compress.toUTF8
  store.setRef (stateRef hash) hash
  for tree in treesOf state do
    store.setRef (workspaceRef tree) tree
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

/-- Deletes a state and its whole subtree, then reclaims every blob no longer reachable. -/
def removeSubtree (store : Store) (hash : Hash) : Result Nat := do
  let doomed ← subtree store hash
  -- Re-pin tree refs from the survivors only, so a tree shared with a survivor stays live.
  for h in doomed do
    store.deleteRef (stateRef h)
  let refs ← store.listRefs
  for (name, _) in refs do
    if name.startsWith "workspace." then store.deleteRef name
  let survivors := (← allStates store)
  for s in survivors do
    for tree in treesOf (← getState store s) do
      store.setRef (workspaceRef tree) tree
  let _ ← store.gc
  pure doomed.size

/-! ## Model construction -/

/-- The model stack behind a `provider:name` spec: provider, retry, batch, persistent cache. -/
def buildModel (spec : String) (temperature : Float) (cacheDir : System.FilePath)
    (options : Provider.Options := {}) : Result Model := do
  let base ← Provider.fromSpec spec temperature options
  -- Transport failures are retried: a duplicate request costs less than an aborted run, whose
  -- container — and everything the agent kept outside the workspace — is lost on resume.
  let model ← base.retry { retryUnknownDelivery := true }
  let model ← model.batch .sequential
  Cache.persistent model { directory := cacheDir }

/-! ## Driving the agent, recording each turn as a state -/

/-- Where a trajectory's files live and its commands run; the part of a `Runtime` that does not
sample. -/
structure Sandbox where
  store : Store
  /-- Wiped and re-materialized from a snapshot at every checkout; holds nothing durable. -/
  workDir : System.FilePath
  executor : Executor

/-- The live run: a sandbox, the model, and the agent being driven. -/
structure Runtime extends Sandbox where
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
private partial def follow (rt : Runtime) (log : Log) (appended : Log) (workspace : Hash) :
    Result (Log × Hash × Option Question × Halt) := do
  match rt.agent.next log with
  | .sample => pure (appended, workspace, none, .continue)
  | .done outcome => pure (appended, workspace, none, .outcome outcome)
  | .ask callId text =>
    let question : Question := { callId, text }
    pure (appended, workspace, some question, .question question)
  | .act call =>
    let content ← rt.agent.act { dir := rt.workDir } call
    let workspace ← rt.store.snapshot rt.workDir
    let event := Event.observation call.id content
    follow rt (log.push event) (appended.push event) workspace

/-- Runs one model turn from `parent` (whose log is `log` and workspace is `workspace`, already
materialized into `rt.workDir`), records it as a new child state, and returns the child, its log,
its workspace, and why the turn stopped, if it did. -/
def advance (rt : Runtime) (note : String) (parent : Hash) (log : Log) (workspace : Hash) :
    Result (Hash × Log × Hash × Halt) := do
  -- Draw index = the number of children that came from sampling.
  let mut childCount := 0
  for child in ← children rt.store parent do
    let kind := (← getState rt.store child).kind
    if kind == .turn || kind == .question then childCount := childCount + 1
  -- Children run in whatever the parent ran in; the image is a property of the trajectory.
  let image? := (← getState rt.store parent).image?
  let stream ← rt.model.sample { messages := rt.agent.view log, tools := rt.agent.tools }
  let responses ← stream.nextN (childCount + 1)
  let response ← match responses[childCount]? with
    | some response => pure response
    | none => throw <| .protocol "model returned too few responses"
  let event := Event.response response
  let (appended, workspace, question?, halt) ← follow rt (log.push event) #[event] workspace
  let outcome? := match halt with | .outcome o => some o | _ => none
  let child ← putState rt.store {
    parent? := some parent, workspace, appended, outcome?, question?
    kind := if question?.isSome then .question else .turn
    note? := some note, image? }
  pure (child, log ++ appended, workspace, halt)

/-- Materializes `workspace` into `rt.workDir`, replacing whatever is there. Relies on
`MaterializeConfig.verify` (the default): the run's commands modify the directory after every
checkout, and an incremental apply against the stale record would keep those writes. -/
private def checkoutInto (sandbox : Sandbox) (workspace : Hash) : Result Unit :=
  sandbox.store.materialize workspace sandbox.workDir { onExisting := .replace }

/-- Advances exactly one model turn from `hash`, returning the new child state. -/
def stepOnce (rt : Runtime) (note : String) (hash : Hash) : Result Hash := do
  let state ← getState rt.store hash
  Result.fromExcept Error.configuration state.continuable
  checkoutInto rt.toSandbox state.workspace
  let (child, _, _, _) ← advance rt note hash (← logOf rt.store hash) state.workspace
  pure child

/-- Grows a continuation from `hash` until the run ends or stops at a question, returning the
state it stopped at. -/
partial def resume (rt : Runtime) (note : String) (hash : Hash)
    (onStep : Hash -> Result Unit) : Result Hash := do
  let start ← getState rt.store hash
  Result.fromExcept Error.configuration start.continuable
  checkoutInto rt.toSandbox start.workspace
  let rec go (parent : Hash) (log : Log) (workspace : Hash) : Result Hash := do
    let (child, log, workspace, halt) ← advance rt note parent log workspace
    onStep child
    match halt with
    | .continue => go child log workspace
    | _ => pure child
  go hash (← logOf rt.store hash) start.workspace

/-! ## Evaluation -/

/-- The grader command with its placeholders expanded: `{checkout}` is the directory holding the
state's files, `{out}` an empty directory for whatever the grader wants kept. -/
def expandGrader (grader : String) (checkout out : System.FilePath) : String :=
  (grader.replace "{checkout}" checkout.toString).replace "{out}" out.toString

/-- Keeps a grader's output readable in `show` without putting megabytes in a state blob. -/
private def truncateOutput (s : String) : String :=
  if s.length <= 20000 then s
  else
    let elided := s.length - 20000
    String.ofList (s.toList.take 10000) ++ s!"\n… {elided} characters elided …\n" ++
      String.ofList (s.toList.drop (s.length - 10000))

/-- An evaluation of `hash` that already ran this grader. -/
def evaluationOf? (store : Store) (hash : Hash) (grader : String) : Result (Option Hash) := do
  for child in ← children store hash do
    let state ← getState store child
    if state.kind == .evaluation then
      if let some e := state.evaluation? then
        if e.grader == grader then return some child
  pure none

/-- Empties `dir`, creating it if needed. -/
private def emptyDir (dir : System.FilePath) : Result Unit :=
  Result.fromIO Error.storage do
    if ← dir.pathExists then IO.FS.removeDirAll dir
    IO.FS.createDirAll dir

/-- Whether `dir` has any entry. -/
private def nonEmpty (dir : System.FilePath) : Result Bool :=
  Result.fromIO Error.storage do pure (!(← dir.readDir).isEmpty)

/-- Runs `grader` on the host against a fresh checkout of `hash`'s workspace and records the
verdict as a leaf child whose workspace is the checkout after the grader ran. `scratch` is a directory the trajectory may wipe: the checkout and the
grader's output directory are made under it. -/
def evaluate (store : Store) (scratch : System.FilePath) (hash : Hash) (grader : String)
    (timeoutSeconds : Nat := 900) (force : Bool := false) : Result Hash := do
  let state ← getState store hash
  if state.kind == .evaluation then
    throw <| .configuration "cannot evaluate an evaluation: it is already a leaf"
  if !force then
    if let some existing ← evaluationOf? store hash grader then return existing
  -- Absolute, so a grader that changes directory still finds them.
  Result.fromIO Error.storage (IO.FS.createDirAll scratch)
  let scratch ← Result.fromIO Error.storage (IO.FS.realPath scratch)
  let checkout := scratch / "checkout"
  let out := scratch / "out"
  emptyDir checkout
  emptyDir out
  store.materialize state.workspace checkout { onExisting := .replace }
  let command := expandGrader grader checkout out
  let runner := Executor.onHost { timeoutSeconds }
  let started ← Result.fromIO Error.storage IO.monoMsNow
  -- In the caller's directory, so relative paths in the command are the person's, not the checkout's.
  let output ← Result.fromIO Error.storage (runner.bash (← Result.fromIO Error.storage IO.currentDir) command)
  let elapsedMs := (← Result.fromIO Error.storage IO.monoMsNow) - started
  let evidence? ← if ← nonEmpty out then some <$> store.snapshot out else pure none
  let summary? ← Result.fromIO Error.storage do
    let verdict := out / "verdict.json"
    if !(← verdict.pathExists) then pure none
    else match Lean.Json.parse (← IO.FS.readFile verdict) with
      | .ok json => pure (some json)
      | .error _ => pure none
  -- The evaluation's workspace is the checkout as the grader left it, so the tree shows what
  -- the grader did to the files; the leaf rule keeps it out of any state a run continues from.
  let graded ← store.snapshot checkout
  Result.fromIO Error.storage (IO.FS.removeDirAll checkout)
  putState store {
    parent? := some hash, workspace := graded, kind := .evaluation, appended := #[]
    image? := state.image?
    evaluation? := some {
      grader, returncode := output.exitCode?.map (fun c => Int.ofNat c.toNat) |>.getD (-1), elapsedMs
      output := truncateOutput (output.output ++
        (match output.error? with | some e => s!"\n{e}" | none => ""))
      evidence?, summary? } }

/-! ## Root creation and what a person adds -/

/-- Creates a root state from the initial project directory: the agent's opening log — its
prompts — and a snapshot of `project`. -/
def createRoot (store : Store) (log : Log) (project : System.FilePath)
    (note? : Option String := none) (image? : Option String := none) : Result Hash := do
  let workspace ← store.snapshot project
  putState store { parent? := none, workspace, kind := .root, appended := log, note?, image? }

/-- A state a person may build on: anything but an evaluation, which is a leaf, or a state
waiting for an answer, which `reply` alone grows. An ended run is fine: fixing something after a
submission and continuing is what interventions are for. -/
private def buildable (state : State) : Result Unit := do
  if state.kind == .evaluation then
    throw <| .configuration "cannot build on an evaluation: it is a verdict, not a point in the run"
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

/-- Records a hand-edited workspace `dir` as an intervention child of `hash`, with a notice to
the model when `tell?` is given. -/
def commit (store : Store) (hash : Hash) (dir : System.FilePath) (note? : Option String)
    (tell? : Option String := none) : Result Hash := do
  let parent ← getState store hash
  buildable parent
  let workspace ← store.snapshot dir
  let intervention? ← match tell? with
    | none => pure none
    | some message =>
      pure (some ({ message, changed := ← changedLines store parent.workspace workspace } : Intervention))
  putState store {
    parent? := some hash, workspace, kind := .intervention, note?
    appended := intervention?.map (fun i => #[Event.message (.user (interventionNotice i))])
      |>.getD #[]
    intervention?, image? := parent.image? }

/-- Records a person's message to the agent as a child of `hash`: same workspace, and the log
grown by one user turn carrying the message in the intervention envelope. -/
def tell (store : Store) (hash : Hash) (message : String) : Result Hash := do
  let parent ← getState store hash
  buildable parent
  let intervention : Intervention := { message }
  putState store {
    parent? := some hash, workspace := parent.workspace, kind := .message
    appended := #[.message (.user (interventionNotice intervention))]
    intervention? := some intervention
    image? := parent.image? }

/-- Answers the question `hash` is waiting on: a child whose one event is the observation of the
asking call, carrying `text` verbatim. -/
def reply (store : Store) (hash : Hash) (text : String) : Result Hash := do
  let parent ← getState store hash
  let question ← match parent.question? with
    | some q => pure q
    | none => throw <| .configuration "this state is not waiting for an answer"
  putState store {
    parent? := some hash, workspace := parent.workspace, kind := .reply
    appended := #[.observation question.callId (.str text)]
    image? := parent.image? }

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

/-! ## Rendering: generic over tools — a call by name and arguments, an observation by its
content. -/

private def take (s : String) (n : Nat) : String := String.ofList (s.toList.take n)

private def short (h : Hash) : String := take h.hex 12

private def flatten (s : String) (limit : Nat := 60) : String :=
  let flat := (s.replace "\n" " ").replace "\r" " "
  if flat.length > limit then take flat (limit - 3) ++ "..." else flat

/-- The arguments of a call as one string: the value of the one string field, or of a string
`command` field beside others — the shapes a command tool takes — otherwise the compact JSON, or
the raw text when it did not parse. -/
def argumentsSummary (call : Chat.ToolCall) : String :=
  match call.invalidArguments? with
  | some raw => raw
  | none =>
    match call.arguments with
    | .obj fields =>
      match fields.foldl (fun (acc : Array (String × Lean.Json)) k v => acc.push (k, v)) #[] with
      | #[(_, Lean.Json.str value)] => value
      | _ =>
        match call.arguments.getObjVal? "command" with
        | .ok (Lean.Json.str command) => command
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
    | some e => s!"eval  [{e.verdict}]  " ++ flatten e.grader
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
    s!"workspace {state.workspace.hex}"]
  if let some note := state.note? then lines := lines.push s!"note     {note}"
  if let some image := state.image? then lines := lines.push s!"image    {image}"
  if let some e := state.evaluation? then
    lines := lines.push s!"grader   {e.grader}"
    lines := lines.push s!"verdict  {if e.passed then "pass" else "fail"} (rc={e.returncode}, {e.elapsedMs} ms)"
    if let some (passed, total) := e.score? then lines := lines.push s!"score    {passed}/{total}"
    if let some evidence := e.evidence? then lines := lines.push s!"evidence {evidence.hex}"
    if let some summary := e.summary? then lines := lines.push s!"summary  {summary.compress}"
    lines := lines.push "--- grader output ---"
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
  changedLines store sa.workspace sb.workspace

end Alaya.Trajectory
