import Alaya

/-! `alaya` — the command-line driver. See README.md for what the commands do. -/

open Alaya
open Alaya.Cas (Store Hash)
open Alaya.Agent (Outcome)
open Alaya.Agent.MiniSwe (Config Runtime)
open Alaya.Agent.MiniSwe.Session

private def emit (s : String) : Result Unit := Result.fromIO Error.storage (IO.println s)

private def emitLines (lines : Array String) : Result Unit :=
  lines.forM emit

/-- The data directory: every durable artefact of every run, namely the content-addressed store
under `path/store` and the model cache under `path/cache`. The agent never executes here, and
nothing in here is ever destroyed by a checkout. Selected by `--data` (default `.alaya`). -/
private structure DataDir where
  path : System.FilePath
  store : Store

private def DataDir.cache (data : DataDir) : System.FilePath := data.path / "cache"

private def openData (args : Cli.Args) : Result DataDir := do
  let path : System.FilePath := ← args.valueD "data" ".alaya"
  let store ← Store.create (path / "store")
  pure { path, store }

/-- The work directory: where the agent runs its commands, and nothing else. Every checkout
wipes it and re-materializes it from a snapshot, so whatever is here that has not been captured
into the store is lost. Selected by `--work` (default `.alaya-work`). -/
private structure WorkDir where
  path : System.FilePath

/-- Whether either path is the other or contains it. -/
private def overlapping (a b : System.FilePath) : Bool :=
  a == b || a.toString.startsWith s!"{b.toString}/" || b.toString.startsWith s!"{a.toString}/"

private def overlapError (work data : System.FilePath) : Error :=
  .configuration <|
    s!"--work {work} overlaps --data {data}: the work directory is wiped on every checkout, " ++
    "so it must stay outside the directory that stores the trajectory tree"

/-- Opens the work directory, refusing any path that overlaps `data` — the agent's directory is
destroyed on every checkout and must never contain stored data. The check runs before the
directory is created, so a rejected `--work` leaves nothing behind, and again after, since only
a resolved path sees through symlinks. -/
private def openWork (data : DataDir) (args : Cli.Args) : Result WorkDir := do
  let requested : System.FilePath := ← args.valueD "work" ".alaya-work"
  let dataPath ← Result.fromIO Error.storage (IO.FS.realPath data.path)
  let cwd ← Result.fromIO Error.storage IO.currentDir
  let absolute := if requested.isAbsolute then requested else cwd / requested
  if overlapping absolute dataPath then throw (overlapError absolute dataPath)
  Result.fromIO Error.storage (IO.FS.createDirAll absolute)
  let path ← Result.fromIO Error.storage (IO.FS.realPath absolute)
  if overlapping path dataPath then throw (overlapError path dataPath)
  pure { path }

private def runtimeFor (data : DataDir) (work : WorkDir) (args : Cli.Args) : Result Runtime := do
  let spec ← args.require "model" "e.g. --model yunwu:gpt-5.6-luna"
  let temperature ← args.floatD "temperature" 0.0
  let model ← buildModel spec temperature data.cache (← Provider.Options.ofArgs args)
  pure { model, store := data.store, workDir := work.path, config := { task := "" } }

private def modelSpecOf (args : Cli.Args) : String := args.getD "model" ""

private def run (argv : List String) : Result Unit := do
  let args := Cli.parse argv (aliases := [("-m", "note")])
  match args.positional.toList with
  | ["root", task, project] =>
    let data ← openData args
    let hash ← createRoot data.store { task } project
    emit hash.hex
  | "resume" :: pfx :: _ =>
    let data ← openData args
    let rt ← runtimeFor data (← openWork data args) args
    let start ← resolve data.store pfx
    let final ← resume rt (modelSpecOf args) start fun child => do
      let state ← getState data.store child
      let mark := match state.outcome? with | some o => s!"  [{o.status}]" | none => ""
      emit s!"{child.hex}{mark}"
    match (← getState data.store final).outcome? with
    | some o => emit s!"done: {o.status}"
    | none => pure ()
  | "step" :: pfx :: _ =>
    let data ← openData args
    let rt ← runtimeFor data (← openWork data args) args
    let child ← stepOnce rt (modelSpecOf args) (← resolve data.store pfx)
    emit child.hex
  | ["commit", pfx, dir] =>
    let data ← openData args
    let hash ← commit data.store (← resolve data.store pfx) dir ((args.get? "note").filter (!·.isEmpty))
    emit hash.hex
  | ["checkout", pfx, dir] =>
    let data ← openData args
    let state ← getState data.store (← resolve data.store pfx)
    data.store.materialize state.env dir { onExisting := .replace }
    emit s!"checked out {state.env.hex} into {dir}"
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
      "usage: alaya (root TASK PROJECT | resume HASH --model P:M | step HASH --model P:M | " ++
      "commit HASH DIR [-m NOTE] | checkout HASH DIR | tree | show HASH | diff A B | rm HASH) " ++
      "[--data D] [--work W] [--temperature T] [--url U] [--port N]"

def main (args : List String) : IO UInt32 := do
  match ← (run args).toBaseIO with
  | .ok () => pure 0
  | .error error =>
    IO.eprintln s!"error: {error.describe}"
    pure 1
