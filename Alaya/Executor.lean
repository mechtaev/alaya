import Lean.Data.Json
import Alaya.Error

/-! Where shell commands run: on the host, or (see `Alaya.Executor.Docker`) in a container with
the working directory bind-mounted. The command semantics are described in `docs/miniswe.md` §7. -/

namespace Alaya

open Alaya (Result Error)

/-- The result of executing one command. -/
structure Output where
  /-- Stdout and stderr, merged, as far as the command got. -/
  output : String
  /-- The exit status, or `none` when the command did not run to completion: it could not be
  started, or it was killed at the timeout. -/
  exitCode? : Option UInt32 := none
  /-- Why there is no exit status, when there is none. -/
  error? : Option String := none
  deriving Repr, Inhabited, BEq

namespace Output

/-- The observation a shell agent records. -/
def toJson (o : Output) : Lean.Json :=
  .mkObj [("output", o.output),
          ("exit_code", o.exitCode?.map (fun c => Lean.Json.num c.toNat) |>.getD .null),
          ("error", o.error?.map Lean.Json.str |>.getD .null)]

def fromJson? (json : Lean.Json) : Option Output := do
  let output ← (json.getObjVal? "output" >>= Lean.Json.getStr?).toOption
  let exitCode? := (json.getObjVal? "exit_code" >>= Lean.Json.getNat?).toOption.map (·.toUInt32)
  let error? := (json.getObjVal? "error" >>= Lean.Json.getStr?).toOption
  pure { output, exitCode?, error? }

end Output

/-- The `uname` fields of the machine commands run on. -/
structure Uname where
  system : String
  release : String
  version : String
  machine : String
  deriving Repr, Inhabited, BEq

namespace Executor

/-- How commands are run: how long one may take, and what is added to its environment. -/
structure Config where
  /-- Per-command wall-clock timeout in seconds; 0 disables it. -/
  timeoutSeconds : Nat := 30
  /-- Environment overrides layered onto the inherited environment. -/
  env : Array (String × String) := #[]
  deriving Inhabited

end Executor

/-- Where commands run. `exec` runs a shell script (the argv's first element; the rest are its
positional arguments) in a working directory with stderr merged; `display` is the command as it
appears in messages. -/
structure Executor where
  exec : (workDir : System.FilePath) -> (argv : Array String) -> (display : String) -> IO Output
  /-- `uname` where the commands run. -/
  uname : IO Uname
  /-- The pinned image commands run in, recorded in a trajectory; `none` on the host. -/
  image? : Option String := none
  /-- Releases what the executor holds — a container, say — at the end of a run. -/
  close : IO Unit := pure ()

namespace Executor

/-- Decodes UTF-8, replacing each byte that does not start a valid character with U+FFFD. -/
def lossyDecodeUtf8 (bytes : ByteArray) : String := Id.run do
  let mut out := ""
  let mut i := 0
  while i < bytes.size do
    match bytes.utf8DecodeChar? i with
    | some c =>
      out := out.push c
      i := i + c.utf8Size
    | none =>
      out := out.push '�'
      i := i + 1
  return out

/-- The argv for `/bin/sh`: a trampoline that merges stderr into stdout at the fd level and then
execs the inner shell on the script, which it receives as `$1`. Every executor uses it. -/
def trampoline (argv : Array String) : Array String :=
  #["-c", "exec /bin/sh -c \"$@\" 2>&1", "sh"] ++ argv

/-- The observation for a command killed at the timeout, with what it printed before. -/
def timedOut (output display : String) (timeoutSeconds : Nat) : Output :=
  { output, error? := some s!"'{display}' timed out after {timeoutSeconds} seconds" }

/-- The observation for a command that could not be run at all. -/
def failed (message : String) : Output :=
  { output := "", error? := some message }

private partial def pollExit (tryWait : IO (Option UInt32)) (kill : IO Unit) (wait : IO UInt32)
    (readAll : IO String) (deadlineMs timeoutSeconds : Nat) (display : String) : IO Output := do
  match ← tryWait with
  | some code => pure { output := ← readAll, exitCode? := some code }
  | none =>
    if (← IO.monoMsNow) >= deadlineMs then
      kill
      let _ ← wait
      pure (timedOut (← readAll) display timeoutSeconds)
    else
      IO.sleep 20
      pollExit tryWait kill wait readAll deadlineMs timeoutSeconds display

end Executor

/-- `uname` on the host. -/
def Uname.local : IO Uname := do
  let field (flag : String) : IO String := do
    pure (← IO.Process.output { cmd := "uname", args := #[flag] }).stdout.trimAscii.toString
  pure { system := ← field "-s", release := ← field "-r"
         version := ← field "-v", machine := ← field "-m" }

namespace Executor

/-- Runs commands on the host. -/
def onHost (config : Config) : Executor where
  uname := Uname.local
  exec := fun workDir argv display => do
    -- A spawn with an unusable `cwd` exits 255 from the child, which would look like the
    -- command's own status; check first so it is reported as a failure to run.
    if !(← workDir.isDir) then
      return failed s!"working directory {workDir} does not exist or is not a directory"
    try
      let child ← IO.Process.spawn {
        cmd := "/bin/sh"
        args := trampoline argv
        cwd := some workDir
        setsid := true
        stdin := .inherit, stdout := .piped, stderr := .null
        env := config.env.map fun (k, v) => (k, some v) }
      let reader ← IO.asTask (prio := .dedicated) child.stdout.readBinToEnd
      let readAll : IO String := do
        pure (lossyDecodeUtf8 ((← IO.wait reader).toOption.getD ByteArray.empty))
      let deadlineMs := (← IO.monoMsNow) + config.timeoutSeconds * 1000
      pollExit child.tryWait child.kill child.wait readAll deadlineMs config.timeoutSeconds display
    catch e =>
      pure (failed (toString e))

/-- Runs one string command as a shell script. -/
def bash (executor : Executor) (workDir : System.FilePath) (command : String) : IO Output :=
  executor.exec workDir #[command] command

end Executor
end Alaya
