import Alaya.Agent.MiniSwe
import Alaya.Cache
import Alaya.Provider

/-!
A content-addressed **trajectory tree** for the mini-SWE-agent port, and the operations a CLI
drives it with.

Every agent state is a `Dialogue × Cas.Hash` (the model's memory and the workspace snapshot).
We persist each state as a `State` object in the same `Cas.Store`, addressed by its own content
hash — so a state is a node whose parent edge, appended dialogue, and workspace are all captured
by one immutable, deduplicating value, exactly like a git commit. A trajectory is therefore a
tree of these nodes; there are no run names or refs in the user's model — states are addressed by
their hashes, copied from `tree`.

The tree is append-only. Growing a continuation from a node (`resume`/`step`) always creates a
*new* child: at a node that already has `n` children, sampling asks the persistent cache for draw
index `n`, past the recorded draws, so it replays existing branches deterministically and can
never collide with a sibling. An `intervention` (`commit`) records a hand-edited workspace as a
child that shares its parent's dialogue — the model never saw the edit, and discovers it only by
running commands, so its first move replays the parent branch's command against a changed world.

Liveness is tracked with the store's refs (`state.<hex>` for each node, `env.<hex>` for each
workspace it points at); `rm` prunes a subtree by rewriting those refs and running `Store.gc`.
-/

namespace Alaya.Agent.MiniSwe.Session

open Alaya (Result Error)
open Alaya.Agent (Dialogue Outcome)
open Alaya.Cas (Hash Store)

/-! ## Message serialization

Round-trips `Chat.Message` losslessly (including tool-call `arguments` and the raw
`invalidArguments?` string), so a reconstructed dialogue is byte-identical to the one that
produced it and can be sent to the model unchanged. -/

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

def messageToJson : Chat.Message -> Lean.Json
  | .system content => .mkObj [("role", "system"), ("content", content)]
  | .user content => .mkObj [("role", "user"), ("content", content)]
  | .assistant content? toolCalls => .mkObj [
      ("role", "assistant"),
      ("content", content?.map Lean.Json.str |>.getD .null),
      ("tool_calls", .arr (toolCalls.map toolCallToJson))]
  | .tool callId content => .mkObj [
      ("role", "tool"), ("tool_call_id", callId), ("content", content)]

def messageFromJson (json : Lean.Json) : Except String Chat.Message := do
  match ← json.getObjVal? "role" >>= Lean.Json.getStr? with
  | "system" => .system <$> (json.getObjVal? "content" >>= Lean.Json.getStr?)
  | "user" => .user <$> (json.getObjVal? "content" >>= Lean.Json.getStr?)
  | "assistant" =>
    let content? := (json.getObjVal? "content" >>= Lean.Json.getStr?).toOption
    let calls ← match json.getObjVal? "tool_calls" with
      | .ok (.arr calls) => calls.mapM toolCallFromJson
      | _ => pure #[]
    pure (.assistant content? calls)
  | "tool" =>
    let callId ← json.getObjVal? "tool_call_id" >>= Lean.Json.getStr?
    let content ← json.getObjVal? "content"
    pure (.tool callId content)
  | other => throw s!"unknown message role: {other}"

/-! ## State objects -/

/-- What produced a state, for display and provenance. -/
inductive Kind where
  | root
  | agent
  | formatError
  | intervention
  /-- A test run against a state, with an overlay the agent never saw. Always a leaf: see
  `Evaluation`. -/
  | evaluation
  deriving BEq, Repr, Inhabited

def Kind.toString : Kind -> String
  | .root => "root"
  | .agent => "agent"
  | .formatError => "format_error"
  | .intervention => "intervention"
  | .evaluation => "evaluation"

def Kind.ofString? : String -> Option Kind
  | "root" => some .root
  | "agent" => some .agent
  | "format_error" => some .formatError
  | "intervention" => some .intervention
  | "evaluation" => some .evaluation
  | _ => none

/-- The result of running a test command against a state.

This is a separate axis from `Outcome`, which says how a *run* ended: a submitted run can fail
its tests and a run that hit the step limit can pass them. -/
structure Evaluation where
  command : String
  returncode : Int
  elapsedMs : Nat
  /-- Truncated like an observation, so a failing run stays readable in `show`. -/
  output : String
  /-- What was overlaid onto the workspace before the command ran: a directory snapshot, or the
  patch blob. Content-addressed, so the same test set across many trajectories is stored once. -/
  tests? : Option Hash := none
  deriving Inhabited

def Evaluation.passed (evaluation : Evaluation) : Bool := evaluation.returncode == 0

/-- One command run within a state's turn, recorded for `tree`/`show`. -/
structure Command where
  command : Lean.Json
  returncode : Int
  deriving Inhabited

/-- A node of the trajectory tree, content-addressed in the store. `appended` are the messages
this state adds to its parent's dialogue (the full dialogue is the concatenation from the root);
`env` is the workspace snapshot after this state's turn. -/
structure State where
  parent? : Option Hash
  env : Hash
  kind : Kind
  /-- Messages appended on the edge from the parent to this state. -/
  appended : Array Chat.Message
  /-- Commands executed this turn (empty for root, format errors, interventions). -/
  commands : Array Command := #[]
  /-- The run outcome, when this state ended the run (submission or repeated format error). -/
  outcome? : Option Outcome := none
  /-- Provenance: the model spec that produced this turn, or an intervention note. -/
  note? : Option String := none
  /-- The verdict, on an `evaluation` state. -/
  evaluation? : Option Evaluation := none
  /-- The commit the project started at, inherited from the root, when it was a git checkout.
  Evaluation restores the files a test patch touches to this commit first, so an agent that
  edited the tests cannot decide its own verdict. -/
  baseCommit? : Option String := none
  /-- The pinned container image the commands of this trajectory run in, inherited from the
  parent, or `none` when it runs on the host. Recorded so a continuation runs the same bits the
  earlier turns did — and so the `uname` frozen into the root dialogue stays true. -/
  image? : Option String := none
  deriving Inhabited

namespace State

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

def toJson (state : State) : Lean.Json :=
  .mkObj [
    ("v", (1 : Nat)),
    ("parent", state.parent?.map (Lean.Json.str ·.hex) |>.getD .null),
    ("env", state.env.hex),
    ("kind", state.kind.toString),
    ("appended", .arr (state.appended.map messageToJson)),
    ("commands", .arr (state.commands.map fun c =>
      .mkObj [("command", c.command), ("returncode", (c.returncode : Lean.Json))])),
    ("outcome", state.outcome?.map outcomeToJson |>.getD .null),
    ("note", state.note?.map Lean.Json.str |>.getD .null),
    ("image", state.image?.map Lean.Json.str |>.getD .null),
    ("base_commit", state.baseCommit?.map Lean.Json.str |>.getD .null),
    ("evaluation", state.evaluation?.map evaluationToJson |>.getD .null)]

def fromJson (json : Lean.Json) : Except String State := do
  let parent? := (json.getObjVal? "parent" >>= Lean.Json.getStr?).toOption.map (⟨·⟩)
  let env : Hash := ⟨← json.getObjVal? "env" >>= Lean.Json.getStr?⟩
  let kind ← match Kind.ofString? (← json.getObjVal? "kind" >>= Lean.Json.getStr?) with
    | some kind => pure kind
    | none => throw "unknown state kind"
  let appended ← (← json.getObjVal? "appended" >>= Lean.Json.getArr?).mapM messageFromJson
  let commands ← (← json.getObjVal? "commands" >>= Lean.Json.getArr?).mapM fun c => do
    let command ← c.getObjVal? "command"
    let returncode ← c.getObjVal? "returncode" >>= Lean.Json.getInt?
    pure ({ command, returncode } : Command)
  let outcome? ← match json.getObjVal? "outcome" with
    | .ok .null => pure none
    | .ok o => some <$> outcomeFromJson o
    | .error _ => pure none
  let note? := (json.getObjVal? "note" >>= Lean.Json.getStr?).toOption
  -- Absent in states written before images were recorded, which is exactly `none`.
  let image? := (json.getObjVal? "image" >>= Lean.Json.getStr?).toOption
  let baseCommit? := (json.getObjVal? "base_commit" >>= Lean.Json.getStr?).toOption
  let evaluation? ← match json.getObjVal? "evaluation" with
    | .ok .null => pure none
    | .ok e => some <$> evaluationFromJson e
    | .error _ => pure none
  pure { parent?, env, kind, appended, commands, outcome?, note?, image?, baseCommit?
         evaluation? }

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

/-- Reconstructs the full dialogue at `hash` by concatenating appended messages root→node. -/
partial def dialogueOf (store : Store) (hash : Hash) : Result Dialogue := do
  let state ← getState store hash
  let ancestors ← match state.parent? with
    | some parent => dialogueOf store parent
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
  let model ← base.retry {}
  let model ← model.batch .sequential
  Cache.persistent model { directory := cacheDir }

/-! ## Driving the loop, recording each turn as a state -/

private def assistantOf (response : Chat.Response) : Chat.Message :=
  .assistant response.content? response.toolCalls

/-- Runs one model turn from `parent` (whose dialogue is `dialogue` and workspace is `env`,
already materialized into `rt.workDir`), records the resulting turn as a new child state, and
returns the child, its dialogue, its workspace, the new consecutive-format-error count, and the
run outcome if the turn ended the run.

Sampling asks for draw index `= childCount parent`, replaying recorded branches and appending
exactly one new draw — so a new continuation is always a fresh sibling, and an interrupted run
resumes deterministically from its cache. -/
def advance (rt : Runtime) (modelSpec : String) (parent : Hash) (dialogue : Dialogue)
    (env : Hash) (consecutiveFormatErrors : Nat) :
    Result (Hash × Dialogue × Hash × Nat × Option Outcome) := do
  -- Only children that came from sampling consume a draw: an evaluation or an intervention is
  -- recorded against a state without asking the model anything, and counting it would push the
  -- next continuation past a draw the cache holds, costing a request to replay a branch.
  let mut childCount := 0
  for child in ← children rt.store parent do
    let kind := (← getState rt.store child).kind
    if kind == .agent || kind == .formatError then childCount := childCount + 1
  -- Children run in whatever the parent ran in; the image and base commit are properties of
  -- the trajectory.
  let parentState ← getState rt.store parent
  let (image?, baseCommit?) := (parentState.image?, parentState.baseCommit?)
  let stream ← rt.model.sample { messages := dialogue, tools := #[bashTool] }
  let responses ← stream.nextN (childCount + 1)
  let response ← match responses[childCount]? with
    | some response => pure response
    | none => throw <| .protocol "model returned too few responses"
  match parseActions response with
  | .formatError message =>
    let consecutiveFormatErrors := consecutiveFormatErrors + 1
    let outcome? :=
      if rt.config.maxConsecutiveFormatErrors > 0 &&
          consecutiveFormatErrors >= rt.config.maxConsecutiveFormatErrors
      then some { status := "RepeatedFormatError" } else none
    -- Mini drops the offending assistant turn and appends the error as a user turn; env is
    -- unchanged, so this state reuses the parent's workspace snapshot.
    let appended := #[Chat.Message.user message]
    let child ← putState rt.store {
      parent? := some parent, env, kind := .formatError, appended,
      outcome?, note? := some modelSpec, image?, baseCommit? }
    pure (child, dialogue ++ appended, env, consecutiveFormatErrors, outcome?)
  | .actions actions =>
    let assistant := assistantOf response
    let mut env := env
    let mut observations : Array Chat.Message := #[]
    let mut commands : Array Command := #[]
    let mut submitted : Option Outcome := none
    for (id, command) in actions do
      if submitted.isNone then
        let (output, env') ← step rt command
        env := env'
        commands := commands.push { command, returncode := output.returncode }
        match submission? output.output output.returncode with
        | some sub => submitted := some { status := "Submitted", submission := sub }
        | none => observations := observations.push (.tool id (.str (observation output)))
    let appended := #[assistant] ++ observations
    let child ← putState rt.store {
      parent? := some parent, env, kind := .agent, appended, commands,
      outcome? := submitted, note? := some modelSpec, image?, baseCommit? }
    pure (child, dialogue ++ appended, env, 0, submitted)

/-- Materializes `state`'s workspace into `rt.workDir`, replacing whatever is there.

The work directory is modified after every checkout — by the commands of the run, and by the
overlay an evaluation applies — so `MaterializeConfig.verify`, on by default, is what keeps this
sound: without re-capturing the directory first, an incremental materialize would trust a stale
record and leave everything those writes added, so a fork would start from the abandoned
branch's files and a turn after an evaluation would start from the hidden tests. -/
private def checkoutInto (rt : Runtime) (env : Hash) : Result Unit :=
  rt.store.materialize env rt.workDir { onExisting := .replace }

/-- Advances exactly one model turn from `hash`, returning the new child state. -/
def stepOnce (rt : Runtime) (modelSpec : String) (hash : Hash) : Result Hash := do
  let state ← getState rt.store hash
  if state.outcome?.isSome then
    throw <| .configuration "cannot continue: this state already ended the run"
  if state.kind == .evaluation then
    throw <| .configuration
      "cannot continue from an evaluation: its workspace holds tests the agent never saw"
  checkoutInto rt state.env
  let dialogue ← dialogueOf rt.store hash
  let (child, _, _, _, _) ← advance rt modelSpec hash dialogue state.env 0
  pure child

/-- Grows a continuation from `hash` to completion (submission or repeated format error),
returning the final state. -/
partial def resume (rt : Runtime) (modelSpec : String) (hash : Hash)
    (onStep : Hash -> Result Unit) : Result Hash := do
  let start ← getState rt.store hash
  if start.outcome?.isSome then
    throw <| .configuration "cannot continue: this state already ended the run"
  if start.kind == .evaluation then
    throw <| .configuration
      "cannot continue from an evaluation: its workspace holds tests the agent never saw"
  checkoutInto rt start.env
  let dialogue ← dialogueOf rt.store hash
  let rec go (parent : Hash) (dialogue : Dialogue) (env : Hash) (cfe : Nat) : Result Hash := do
    let (child, dialogue, env, cfe, outcome?) ← advance rt modelSpec parent dialogue env cfe
    onStep child
    match outcome? with
    | some _ => pure child
    | none => go child dialogue env cfe
  go hash dialogue start.env 0

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
      let reset ← Result.fromIO Error.storage <| execBash rt <|
        s!"for p in {quoted}; do git checkout {base} -- \"$p\" 2>/dev/null || rm -f \"$p\"; done"
      if reset.returncode != 0 then
        throw <| .configuration s!"restoring test files to {base} failed: {reset.output}"
    Result.fromIO Error.storage (IO.FS.writeFile (rt.workDir / patchFile) contents)
    let applied ← Result.fromIO Error.storage <| execBash rt s!"git apply -v {patchFile}"
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
one — and under `rt.config.timeoutSeconds`, which a caller should set far higher than the
agent's per-command limit. Re-evaluating the same state, command, and overlay returns the
existing node unless `force`. -/
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
  let output ← Result.fromIO Error.storage (execBash rt command)
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

/-! ## Root creation and interventions -/

/-- Creates a root state from the initial project directory: the system+instance dialogue and a
snapshot of `project`. -/
def createRoot (store : Store) (config : Config) (project : System.FilePath)
    (uname : Uname) (image? : Option String := none) (baseCommit? : Option String := none) :
    Result Hash := do
  let env ← store.snapshot project
  putState store {
    parent? := none, env, kind := .root, appended := initialDialogue config uname
    note? := some config.task, image?, baseCommit? }

/-- Records a hand-edited workspace `dir` as an intervention child of `hash`: same dialogue, new
workspace snapshot, marked distinctly. -/
def commit (store : Store) (hash : Hash) (dir : System.FilePath) (note? : Option String) :
    Result Hash := do
  let parent ← getState store hash
  if parent.kind == .evaluation then
    throw <| .configuration
      "cannot build on an evaluation: its workspace holds tests the agent never saw"
  let env ← store.snapshot dir
  putState store {
    parent? := some hash, env, kind := .intervention, appended := #[], note?
    image? := parent.image?, baseCommit? := parent.baseCommit? }

/-! ## Rendering -/

private def take (s : String) (n : Nat) : String := String.ofList (s.toList.take n)

private def short (h : Hash) : String := take h.hex 12

private def commandSummary (json : Lean.Json) : String :=
  let s := match json with | .str s => s | other => other.compress
  let flat := (s.replace "\n" " ").replace "\r" " "
  if flat.length > 60 then take flat 57 ++ "..." else flat

private def label (state : State) : String :=
  match state.kind with
  | .root => "root  " ++ commandSummary (.str (state.note?.getD ""))
  | .agent =>
    let cmd := match state.commands[0]? with | some c => commandSummary c.command | none => "(no command)"
    let rc := match state.commands.back? with | some c => s!" rc={c.returncode}" | none => ""
    "bash  " ++ cmd ++ rc
  | .formatError => "format-error"
  | .intervention => "commit  " ++ (state.note?.getD "")
  | .evaluation =>
    match state.evaluation? with
    | some e =>
      let verdict := if e.passed then "pass" else s!"fail {e.returncode}"
      s!"eval  [{verdict}]  " ++ commandSummary (.str e.command)
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
    let indent := String.join (List.replicate depth "  ")
    let line := s!"{indent}{short hash}  {label state}{outcomeSuffix state}"
    let mut lines := #[line]
    for kid in (← children store hash) do
      lines := lines ++ (← render kid (depth + 1))
    pure lines
  let mut lines := #[]
  for root in roots do
    lines := lines ++ (← render root 0)
  pure lines

/-- Renders a state for `show`: metadata followed by the full reconstructed dialogue. -/
def showLines (store : Store) (hash : Hash) : Result (Array String) := do
  let state ← getState store hash
  let dialogue ← dialogueOf store hash
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
  lines := lines.push "--- dialogue ---"
  for message in dialogue do
    let (role, body) := match message with
      | .system c => ("system", c)
      | .user c => ("user", c)
      | .assistant c? calls =>
        let cmds := calls.toList.map fun (call : Chat.ToolCall) =>
          match call.arguments.getObjVal? "command" with
          | .ok (.str s) => s
          | _ => call.invalidArguments?.getD call.arguments.compress
        ("assistant", (c?.getD "") ++ (if cmds.isEmpty then "" else
          "\n[bash] " ++ "\n[bash] ".intercalate cmds))
      | .tool _ content => ("tool", match content with | .str s => s | j => j.compress)
    lines := lines.push s!"[{role}]"
    lines := lines.push body
  pure lines

/-- The workspace changes from `a`'s snapshot to `b`'s, as `Store.diff` lines. -/
def diffLines (store : Store) (a b : Hash) : Result (Array String) := do
  let sa ← getState store a
  let sb ← getState store b
  let changes ← store.diff sa.env sb.env
  pure <| changes.map fun
    | .added path _ _ => s!"+ {path}"
    | .removed path _ => s!"- {path}"
    | .modified path _ _ => s!"M {path}"

end Alaya.Agent.MiniSwe.Session
