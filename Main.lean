import Alaya

/-! `alaya` — the command-line driver. See README.md for what the commands do. -/

open Alaya
open Alaya.Cas (Store Hash)
open Alaya.Agent (Outcome)
open Alaya.Agent.MiniSwe
open Alaya.Agent.MiniSwe.Session

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
private def executorFor (args : Cli.Args) (image? : Option String) (config : Config) :
    Result Executor := do
  match image? with
  | none =>
    if args.isSet "image" then
      throw <| .configuration <|
        "this trajectory runs on the host: it was created without --image, and its prompt " ++
        "describes the host. Start a new one with `alaya root TASK PROJECT --image IMAGE`"
    pure (Executor.local config)
  | some pinned =>
    let settings ← Docker.settingsFor args pinned
    match ← Docker.settings? args with
    | none => settings.verifyPresent
    | some requested =>
      let requested ← requested.pin
      if requested.image != pinned then
        throw <| .configuration <|
          s!"--image resolves to {requested.image}, but this trajectory runs {pinned}; " ++
          "a continuation has to run the same bits its earlier turns did"
    Docker.executor settings config

private def runtimeFor (data : DataDir) (work : WorkDir) (args : Cli.Args)
    (image? : Option String) : Result Runtime := do
  let spec ← args.require "model" "e.g. --model yunwu:gpt-5.6-luna"
  let temperature ← args.floatD "temperature" 0.0
  let model ← buildModel spec temperature data.cache (← Provider.Options.ofArgs args)
  let config : Config := { task := "" }
  let executor ← executorFor args image? config
  pure { model, store := data.store, workDir := work.path, executor, config }

/-- The `uname` a new trajectory's prompt is built from, and the image it is pinned to: read
from the image when there is one, from the host otherwise. -/
private def rootEnvironment (settings? : Option Docker.Settings) :
    Result (Uname × Option String) := do
  match settings? with
  | none => pure (← Result.fromIO Error.configuration Uname.local, none)
  | some settings => pure (← Docker.uname settings, some settings.image)

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
private def rootProject (args : Cli.Args) (data : DataDir) (settings? : Option Docker.Settings)
    (project? : Option String) : Result System.FilePath := do
  match project?, args.get? "path" with
  | some project, none => pure project
  | none, some path =>
    if path.isEmpty then throw <| .configuration "--path needs a value (e.g. --path /testbed)"
    match settings? with
    | none => throw <| .configuration "--path names a path inside an image: pass --image too"
    | some settings =>
      let work ← clearWork data
      Docker.copyOut settings path work.path
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
session applies it. -/
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
      Docker.copyOut (← Docker.settingsFor args pinned) path extracted
      pure (.directory extracted)
  | _, _, _ =>
    throw <| .configuration "give at most one of --tests, --test-patch, --tests-from-image"

/-- A runtime for running tests: no model is needed, and the timeout is a test suite's rather
than a single agent command's. -/
private def evalRuntime (data : DataDir) (work : WorkDir) (args : Cli.Args)
    (image? : Option String) : Result Runtime := do
  let config : Config := { task := "", timeoutSeconds := ← args.natD "timeout" 900 }
  let executor ← executorFor args image? config
  pure {
    model := { identity := .mkObj [("model", "none")]
               sample := fun _ => throw (.configuration "evaluation does not call a model") }
    store := data.store, workDir := work.path, executor, config }

private def dispatch (argv : List String) : Result Unit := do
  let args := Cli.parse argv (aliases := [("-m", "note")])
  match args.positional.toList with
  | "root" :: task :: rest =>
    if rest.length > 1 then
      throw <| .configuration "alaya root TASK (PROJECT | --path PATH --image IMAGE)"
    let data ← openData args
    let settings? ← (← Docker.settings? args).mapM (·.pin)
    let (uname, image?) ← rootEnvironment settings?
    let project ← rootProject args data settings? rest.head?
    let baseCommit? ← baseCommitOf args project
    let hash ← createRoot data.store { task } project uname image? baseCommit?
    emit hash.hex
  | "resume" :: pfx :: _ =>
    let data ← openData args
    let start ← resolve data.store pfx
    let rt ← runtimeFor data (← openWork data) args (← getState data.store start).image?
    try
      let final ← resume rt (modelSpecOf args) start fun child => do
        let state ← getState data.store child
        let mark := match state.outcome? with | some o => s!"  [{o.status}]" | none => ""
        emit s!"{child.hex}{mark}"
      match (← getState data.store final).outcome? with
      | some o => emit s!"done: {o.status}"
      | none => pure ()
    finally
      Result.fromIO Error.storage rt.executor.close
  | "step" :: pfx :: _ =>
    let data ← openData args
    let parent ← resolve data.store pfx
    let rt ← runtimeFor data (← openWork data) args (← getState data.store parent).image?
    try
      emit (← stepOnce rt (modelSpecOf args) parent).hex
    finally
      Result.fromIO Error.storage rt.executor.close
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
    finally
      Result.fromIO Error.storage rt.executor.close
  | ["commit", pfx, dir] =>
    let data ← openData args
    let hash ← commit data.store (← resolve data.store pfx) dir ((args.get? "note").filter (!·.isEmpty))
    emit hash.hex
  | ["checkout", pfx, dir] =>
    let data ← openData args
    let state ← getState data.store (← resolve data.store pfx)
    data.store.materialize state.env dir { onExisting := .replace }
    emit s!"checked out {state.env.hex} into {dir}"
  | "html" :: rest =>
    let data ← openData args
    let out : System.FilePath := rest.head?.getD (data.path / "report.html").toString
    -- Repeatable, and each may list several: --hide .venv --hide __pycache__,.pytest_cache
    let hidden := (args.all "hide").foldl (init := #[]) fun paths value =>
      paths ++ (value.splitOn ",").toArray.filter (!·.isEmpty)
    let page ← Html.report data.store s!"alaya {data.path}" hidden
    Result.fromIO Error.storage (IO.FS.writeFile out page)
    emit s!"wrote {out} ({page.length} bytes)"
  | ["tree"] =>
    let data ← openData args
    emitLines (← treeLines data.store)
  | ["show", pfx] =>
    let data ← openData args
    emitLines (← showLines data.store (← resolve data.store pfx))
  | ["diff", a, b] =>
    let data ← openData args
    emitLines (← diffLines data.store (← resolve data.store a) (← resolve data.store b))
  | ["rm", pfx] =>
    let data ← openData args
    let n ← removeSubtree data.store (← resolve data.store pfx)
    emit s!"removed {n} state(s)"
  | _ =>
    throw <| .configuration <|
      "usage: alaya (root TASK (PROJECT | --path P --image I) | resume HASH --model P:M | step HASH --model P:M | " ++
      "eval HASH --command C | commit HASH DIR [-m NOTE] | checkout HASH DIR | tree | " ++
      "html [FILE] [--hide DIR] | " ++
      "show HASH | diff A B | rm HASH) " ++
      "[--data D] [--temperature T] [--url U] [--port N] [--image IMAGE] [--network N] " ++
      "[--base-commit SHA] [--tests DIR | --test-patch FILE | --tests-from-image PATH] " ++
      "[--timeout S] [--force]"

def main (args : List String) : IO UInt32 := do
  match ← (dispatch args).toBaseIO with
  | .ok () => pure 0
  | .error error =>
    IO.eprintln s!"error: {error.describe}"
    pure 1
