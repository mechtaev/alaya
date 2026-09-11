import Lean.Data.Json
import Alaya.Error

/-!
Where shell commands run: on the host, or (see `Alaya.Executor.Docker`) in a container with the
working directory bind-mounted. An `Executor` is what a shell-using agent acts through and what
a trajectory runs its evaluations with; it changes where a command runs and nothing about what
the command sees.

The command semantics reproduce mini-SWE-agent's `LocalEnvironment` byte-for-byte, because that
is what the `Alaya.Agent.MiniSwe` port is measured against: an `exec /bin/sh -c "$@" 2>&1`
trampoline runs exactly the argv `Popen(command, shell=True, stderr=STDOUT)` would, with stderr
merged at the fd level and stdin inherited; the inherited environment plus overrides; CPython's
lossy `errors="replace"` decoding of the output; and a `setsid` timeout that kills the whole
process group. A failure to execute is an observation with `exceptionInfo`, never an error,
because a run must not die on a spawn failure.
-/

namespace Alaya

open Alaya (Result Error)

/-- The result of executing one command, matching mini's environment output dict. -/
structure Output where
  output : String
  returncode : Int
  exceptionInfo : String := ""
  deriving Repr, Inhabited, BEq

namespace Output

/-- The observation content a shell agent records: the three fields, under mini's names. -/
def toJson (o : Output) : Lean.Json :=
  .mkObj [("output", o.output), ("returncode", (o.returncode : Lean.Json)),
          ("exception_info", o.exceptionInfo)]

def fromJson? (json : Lean.Json) : Option Output := do
  let output ← (json.getObjVal? "output" >>= Lean.Json.getStr?).toOption
  let returncode ← (json.getObjVal? "returncode" >>= Lean.Json.getInt?).toOption
  let exceptionInfo := (json.getObjVal? "exception_info" >>= Lean.Json.getStr?).toOption.getD ""
  pure { output, returncode, exceptionInfo }

end Output

/-- The `uname` fields of the machine commands run on. A prompt that describes the machine has
to read them from the executor, not the host: a container is another operating system. -/
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

/-- Where commands run. `exec` runs an inner argv in a working directory with stderr merged,
as `Popen(shell=True)` would; `display` is the command as it appears in messages. -/
structure Executor where
  exec : (workDir : System.FilePath) -> (argv : Array String) -> (display : String) -> IO Output
  /-- `uname` where the commands run. -/
  uname : IO Uname
  /-- The pinned image commands run in, recorded in a trajectory; `none` on the host. -/
  image? : Option String := none
  /-- Releases what the executor holds — a container, say — at the end of a run. -/
  close : IO Unit := pure ()

namespace Executor

/-- For a UTF-8 lead byte: the sequence length and the valid range of the first continuation
byte (later continuations are always `0x80`–`0xBF`), or `none` for an invalid lead. -/
private def utf8Lead? (b : UInt8) : Option (Nat × UInt8 × UInt8) :=
  if 0xC2 <= b && b <= 0xDF then some (2, 0x80, 0xBF)
  else if b == 0xE0 then some (3, 0xA0, 0xBF)
  else if b == 0xED then some (3, 0x80, 0x9F)
  else if 0xE1 <= b && b <= 0xEF then some (3, 0x80, 0xBF)
  else if b == 0xF0 then some (4, 0x90, 0xBF)
  else if b == 0xF4 then some (4, 0x80, 0x8F)
  else if 0xF1 <= b && b <= 0xF3 then some (4, 0x80, 0xBF)
  else none

/-- Decodes UTF-8 exactly as CPython's `errors="replace"`: each maximal subpart of an
ill-formed sequence becomes one U+FFFD. -/
def lossyDecodeUtf8 (bytes : ByteArray) : String := Id.run do
  let mut out := ""
  let mut i := 0
  while i < bytes.size do
    let b := bytes[i]!
    if b < 0x80 then
      out := out.push (Char.ofNat b.toNat)
      i := i + 1
    else match utf8Lead? b with
      | none =>
        out := out.push '�'
        i := i + 1
      | some (len, lo, hi) =>
        let mut valid := 0
        for j in [1:len] do
          let (lo, hi) := if j == 1 then (lo, hi) else (0x80, 0xBF)
          if valid == j - 1 && i + j < bytes.size &&
              lo <= bytes[i + j]! && bytes[i + j]! <= hi then
            valid := j
        if valid == len - 1 then
          let mut cp := b.toNat &&& (0xFF >>> (len + 1))
          for j in [1:len] do
            cp := (cp <<< 6) ||| ((bytes[i + j]!).toNat &&& 0x3F)
          out := out.push (Char.ofNat cp)
          i := i + len
        else
          out := out.push '�'
          i := i + 1 + valid
  return out

/-- The inner argv `Popen(command, shell=True)` runs, wrapped in the trampoline that merges
stderr into stdout at the fd level and then execs exactly that argv, so shell error messages
and line numbers are byte-identical. Every executor uses it. -/
def trampoline (argv : Array String) : Array String :=
  #["-c", "exec /bin/sh -c \"$@\" 2>&1", "sh"] ++ argv

/-- Mini's timeout observation. -/
def timedOut (output display : String) (timeoutSeconds : Nat) : Output := {
  output, returncode := -1
  exceptionInfo := "An error occurred while executing the command: Command '" ++ display ++
    "' timed out after " ++ toString timeoutSeconds ++ " seconds" }

/-- Mini's observation for a command that could not be executed at all. -/
def failed (message : String) : Output :=
  { output := "", returncode := -1,
    exceptionInfo := s!"An error occurred while executing the command: {message}" }

private partial def pollExit (tryWait : IO (Option UInt32)) (kill : IO Unit) (wait : IO UInt32)
    (readAll : IO String) (deadlineMs timeoutSeconds : Nat) (display : String) : IO Output := do
  match ← tryWait with
  | some code => pure { output := ← readAll, returncode := Int.ofNat code.toNat }
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

/-- Runs commands on the host, exactly like mini's `LocalEnvironment`: in the working directory
with the inherited environment plus overrides, stdin inherited, in a fresh session so a timeout
kills the whole process group. -/
def onHost (config : Config) : Executor where
  uname := Uname.local
  exec := fun workDir argv display => do
    -- Popen raises before running when `cwd` is unusable; Lean's spawn instead exits 255 from
    -- the child, so the check happens here, with CPython's error text.
    if !(← workDir.isDir) then
      let error := if (← workDir.pathExists)
        then s!"[Errno 20] Not a directory: '{workDir}'"
        else s!"[Errno 2] No such file or directory: '{workDir}'"
      return failed error
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
