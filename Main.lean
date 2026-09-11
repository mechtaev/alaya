import Alaya

/-! `alaya` — the command-line driver for the mini-SWE-agent port over a trajectory tree. See
`docs/trajectory-schema.md` for the commands. -/

open Alaya
open Alaya.Cas (Store Hash)
open Alaya.Agent (Outcome)
open Alaya.Trajectory
open Alaya.Agent.MiniSwe (Config initialLog)

private def emit (s : String) : Result Unit := Result.fromIO Error.storage (IO.println s)

private def emitLines (lines : Array String) : Result Unit :=
  lines.forM emit

/-- The data directory: everything one set of runs needs, namely the content-addressed store
under `path/store`, the model cache under `path/cache`, and the agent's work directory under
`path/work`. Selected by `--data` (default `.alaya`), the only directory flag there is. -/
private structure DataDir where
  path : System.FilePath
  store : Store

private def DataDir.cache (data : DataDir) : System.FilePath := data.path / "cache"

private def openData (args : Cli.Args) : Result DataDir := do
  let path : System.FilePath := ← args.valueD "data" ".alaya"
  let store ← Store.create (path / "store")
  pure { path, store }

/-- The work directory: where the agent runs its commands, and nothing else. It is always
`DATA/work`, and it is the one place in the data directory that holds nothing durable — every
checkout wipes it and re-materializes it from a snapshot, so whatever is in it that was not
captured into the store is lost. Not configurable, so no path a user names can be destroyed by
a checkout, and the store and the cache are out of its reach by construction. -/
private structure WorkDir where
  path : System.FilePath

private def openWork (data : DataDir) : Result WorkDir := do
  let path := data.path / "work"
  Result.fromIO Error.storage (IO.FS.createDirAll path)
  pure { path }

/-- Where a run's commands go. A trajectory records the image its earlier turns ran in — and its
root dialogue tells the model the `uname` of that image — so a continuation is pinned to it: the
recorded image is used as given, and a `--image` that resolves to anything else is refused. -/
private def executorFor (args : Cli.Args) (image? : Option String) (config : Executor.Config) :
    Result Executor := do
  match image? with
  | none =>
    if args.isSet "image" then
      throw <| .configuration <|
        "this trajectory runs on the host: it was created without --image, and its prompt " ++
        "describes the host. Start a new one with `alaya root TASK PROJECT --image IMAGE`"
    pure (Executor.onHost config)
  | some pinned =>
    let settings ← Executor.Docker.settingsFor args pinned
    match ← Executor.Docker.settings? args with
    | none => settings.verifyPresent
    | some requested =>
      let requested ← requested.pin
      if requested.image != pinned then
        throw <| .configuration <|
          s!"--image resolves to {requested.image}, but this trajectory runs {pinned}; " ++
          "a continuation has to run the same bits its earlier turns did"
    Executor.Docker.executor settings config

/-- The mini agent over an executor, with the given command timeout. -/
private def miniAgent (executor : Executor) (config : Config) : Agent.Agent :=
  Agent.MiniSwe.agent executor config

private def runtimeFor (data : DataDir) (work : WorkDir) (args : Cli.Args)
    (image? : Option String) : Result Runtime := do
  let spec ← args.require "model" "e.g. --model yunwu:gpt-5.6-luna"
  let temperature ← args.floatD "temperature" 0.0
  let model ← buildModel spec temperature data.cache (← Provider.Options.ofArgs args)
  let config : Config := { task := "" }
  let executor ← executorFor args image? config.executor
  pure { store := data.store, workDir := work.path, executor, model
         agent := miniAgent executor config }

/-- The `uname` a new trajectory's prompt is built from, and the image it is pinned to: read
from the image when there is one, from the host otherwise. -/
private def rootEnvironment (settings? : Option Executor.Docker.Settings) :
    Result (Uname × Option String) := do
  match settings? with
  | none => pure (← Result.fromIO Error.configuration Uname.local, none)
  | some settings => pure (← Executor.Docker.uname settings, some settings.image)

/-- Empties the work directory. Both a checkout and an extraction from an image need it to start
clean, and it is the one place holding nothing durable. -/
private def clearWork (data : DataDir) : Result WorkDir := do
  let work ← openWork data
  Result.fromIO Error.storage do
    IO.FS.removeDirAll work.path
    IO.FS.createDirAll work.path
  pure work

/-- The directory a new trajectory snapshots: a host `PROJECT`, or `--path` copied out of the
image — task images usually carry the project already, so there is nothing on the host to point
at. An extraction lands in the work directory, which is disposable by construction. -/
private def rootProject (args : Cli.Args) (data : DataDir)
    (settings? : Option Executor.Docker.Settings) (project? : Option String) :
    Result System.FilePath := do
  match project?, args.get? "path" with
  | some project, none => pure project
  | none, some path =>
    if path.isEmpty then throw <| .configuration "--path needs a value (e.g. --path /testbed)"
    match settings? with
    | none => throw <| .configuration "--path names a path inside an image: pass --image too"
    | some settings =>
      let work ← clearWork data
      Executor.Docker.copyOut settings path work.path
      pure work.path
  | some _, some _ =>
    throw <| .configuration "give either a PROJECT directory or --path PATH, not both"
  | none, none =>
    throw <| .configuration "alaya root TASK (PROJECT | --path PATH --image IMAGE)"

private def modelSpecOf (args : Cli.Args) : String := args.getD "model" ""

/-- The commit a project starts at, for restoring test files before a patch. Taken from
`--base-commit`, or read from the checkout when it is a git repository. -/
private def baseCommitOf (args : Cli.Args) (project : System.FilePath) :
    Result (Option String) := do
  match args.get? "base-commit" with
  | some commit => pure (some commit)
  | none =>
    let out ← Result.fromIO Error.storage <| IO.Process.output {
      cmd := "git", args := #["-C", project.toString, "rev-parse", "HEAD"] }
    pure (if out.exitCode == 0 then some out.stdout.trimAscii.toString else none)

/-- The tests to overlay before a test command runs. `--tests-from-image` is extracted first,
into a directory beside the workspace, so the overlay is an ordinary directory by the time the
trajectory applies it. -/
private def overlayOf (args : Cli.Args) (data : DataDir) (image? : Option String) :
    Result Overlay := do
  match args.get? "tests", args.get? "test-patch", args.get? "tests-from-image" with
  | none, none, none => pure .nothing
  | some directory, none, none => pure (.directory directory)
  | none, some file, none =>
    pure (.patch (← Result.fromIO Error.storage (IO.FS.readFile file)))
  | none, none, some path =>
    match image? with
    | none => throw <| .configuration "--tests-from-image needs a trajectory pinned to an image"
    | some pinned =>
      let extracted := data.path / "tests"
      Result.fromIO Error.storage do
        IO.FS.removeDirAll extracted
        IO.FS.createDirAll extracted
      Executor.Docker.copyOut (← Executor.Docker.settingsFor args pinned) path extracted
      pure (.directory extracted)
  | _, _, _ =>
    throw <| .configuration "give at most one of --tests, --test-patch, --tests-from-image"

/-- A runtime for running tests: no model is needed, and the timeout is a test suite's rather
than a single agent command's. -/
private def evalRuntime (data : DataDir) (work : WorkDir) (args : Cli.Args)
    (image? : Option String) : Result Runtime := do
  let config : Config := { task := "", timeoutSeconds := ← args.natD "timeout" 900 }
  let executor ← executorFor args image? config.executor
  pure {
    store := data.store, workDir := work.path, executor
    model := { identity := .mkObj [("model", "none")]
               sample := fun _ => throw (.configuration "evaluation does not call a model") }
    agent := miniAgent executor config }

/-- Exit status when a run stopped at a question rather than an outcome, so a supervisor driving
`alaya` as a subprocess can tell the two apart without parsing anything. -/
private def exitWaiting : UInt32 := 3

/-- One line per new state. Plain: the hash, with the outcome or the question it stopped at.
`--json`: one object with `state`, `kind`, `outcome`, and `question`, the last of which a
supervisor reads to know what it is being asked. -/
private def stateLine (data : DataDir) (child : Hash) (json : Bool) : Result Unit := do
  let state ← getState data.store child
  if json then
    emit (Lean.Json.mkObj [
      ("state", child.hex), ("kind", state.kind.toString),
      ("outcome", state.outcome?.map (fun o => Lean.Json.str o.status) |>.getD .null),
      ("question", state.question?.map (fun q => Lean.Json.str q.text) |>.getD .null)]).compress
  else
    let mark := match state.outcome?, state.question? with
      | some o, _ => s!"  [{o.status}]"
      | none, some q => s!"  ask  {q.text.quote}  [Waiting]"
      | none, none => ""
    emit s!"{child.hex}{mark}"

/-- The exit status for the state a run stopped at. -/
private def exitFor (data : DataDir) (hash : Hash) : Result UInt32 := do
  pure (if (← getState data.store hash).question?.isSome then exitWaiting else 0)

private def dispatch (argv : List String) : Result UInt32 := do
  let args := Cli.parse argv (aliases := [("-m", "note")])
  let json := args.isSet "json"
  match args.positional.toList with
  | "root" :: task :: rest =>
    if rest.length > 1 then
      throw <| .configuration "alaya root TASK (PROJECT | --path PATH --image IMAGE)"
    let data ← openData args
    let settings? ← (← Executor.Docker.settings? args).mapM (·.pin)
    let (uname, image?) ← rootEnvironment settings?
    let project ← rootProject args data settings? rest.head?
    let baseCommit? ← baseCommitOf args project
    let hash ← createRoot data.store (initialLog { task } uname) project (some task) image? baseCommit?
    emit hash.hex
    pure 0
  | "resume" :: pfx :: _ =>
    let data ← openData args
    let start ← resolve data.store pfx
    let rt ← runtimeFor data (← openWork data) args (← getState data.store start).image?
    try
      let final ← resume rt (modelSpecOf args) start (stateLine data · json)
      if !json then
        match (← getState data.store final).outcome? with
        | some o => emit s!"done: {o.status}"
        | none => pure ()
      exitFor data final
    finally
      Result.fromIO Error.storage rt.executor.close
  | "step" :: pfx :: _ =>
    let data ← openData args
    let parent ← resolve data.store pfx
    let rt ← runtimeFor data (← openWork data) args (← getState data.store parent).image?
    try
      let child ← stepOnce rt (modelSpecOf args) parent
      stateLine data child json
      exitFor data child
    finally
      Result.fromIO Error.storage rt.executor.close
  | ["tell", pfx, text] =>
    let data ← openData args
    emit (← tell data.store (← resolve data.store pfx) text).hex
    pure 0
  | ["reply", pfx, text] =>
    let data ← openData args
    emit (← reply data.store (← resolve data.store pfx) text).hex
    pure 0
  | ["waiting"] =>
    let data ← openData args
    for (hash, q) in ← waiting data.store do
      if json then emit (Lean.Json.mkObj [("state", hash.hex), ("question", q.text)]).compress
      else emit s!"{hash.hex}  {q.text.quote}"
    pure 0
  | "eval" :: pfx :: _ =>
    let data ← openData args
    let target ← resolve data.store pfx
    let state ← getState data.store target
    let command ← args.require "command" "e.g. --command 'pytest -x tests/test_foo.py'"
    let overlay ← overlayOf args data state.image?
    let rt ← evalRuntime data (← openWork data) args state.image?
    try
      let node ← evaluate rt target command overlay (force := args.isSet "force")
      match (← getState data.store node).evaluation? with
      | some e =>
        let verdict := if e.passed then "pass" else s!"fail {e.returncode}"
        emit s!"{node.hex}  {verdict}  ({e.elapsedMs} ms)"
      | none => emit node.hex
      pure 0
    finally
      Result.fromIO Error.storage rt.executor.close
  | ["commit", pfx, dir] =>
    let data ← openData args
    let hash ← commit data.store (← resolve data.store pfx) dir
      ((args.get? "note").filter (!·.isEmpty)) (tell? := (args.get? "tell").filter (!·.isEmpty))
    emit hash.hex
    pure 0
  | ["checkout", pfx, dir] =>
    let data ← openData args
    let state ← getState data.store (← resolve data.store pfx)
    data.store.materialize state.env dir { onExisting := .replace }
    emit s!"checked out {state.env.hex} into {dir}"
    pure 0
  | "html" :: rest =>
    let data ← openData args
    let out : System.FilePath := rest.head?.getD (data.path / "report.html").toString
    -- Repeatable, and each may list several: --hide .venv --hide __pycache__,.pytest_cache
    let hidden := (args.all "hide").foldl (init := #[]) fun paths value =>
      paths ++ (value.splitOn ",").toArray.filter (!·.isEmpty)
    let page ← Html.report data.store s!"alaya {data.path}" Agent.MiniSwe.view Agent.MiniSwe.tools hidden
    Result.fromIO Error.storage (IO.FS.writeFile out page)
    emit s!"wrote {out} ({page.length} bytes)"
    pure 0
  | ["tree"] =>
    let data ← openData args
    emitLines (← treeLines data.store)
    pure 0
  | ["show", pfx] =>
    let data ← openData args
    let view? := if args.isSet "view" then some Agent.MiniSwe.view else none
    emitLines (← showLines data.store (← resolve data.store pfx) view?)
    pure 0
  | ["diff", a, b] =>
    let data ← openData args
    emitLines (← diffLines data.store (← resolve data.store a) (← resolve data.store b))
    pure 0
  | ["rm", pfx] =>
    let data ← openData args
    let n ← removeSubtree data.store (← resolve data.store pfx)
    emit s!"removed {n} state(s)"
    pure 0
  | _ =>
    throw <| .configuration <|
      "usage: alaya (root TASK (PROJECT | --path P --image I) | resume HASH --model P:M | step HASH --model P:M | " ++
      "eval HASH --command C | commit HASH DIR [-m NOTE] [--tell TEXT] | tell HASH TEXT | " ++
      "reply HASH TEXT | waiting | checkout HASH DIR | tree | " ++
      "html [FILE] [--hide DIR] | " ++
      "show HASH [--view] | diff A B | rm HASH) " ++
      "[--data D] [--json] [--temperature T] [--url U] [--port N] [--echo-reasoning] [--image IMAGE] [--network N] " ++
      "[--base-commit SHA] [--tests DIR | --test-patch FILE | --tests-from-image PATH] " ++
      "[--timeout S] [--force]"

/-- Exit 0 on success, 3 when a run stopped at a question (see `exitWaiting`), 1 on error. -/
def main (args : List String) : IO UInt32 := do
  match ← (dispatch args).toBaseIO with
  | .ok code => pure code
  | .error error =>
    IO.eprintln s!"error: {error.describe}"
    pure 1
