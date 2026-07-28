import Alaya.Agent
import Alaya.Cas

/-!
An exact port of mini-SWE-agent's default tool-calling agent (`mini.yaml` + `litellm_model` +
`actions_toolcall`) onto Alaya's typed architecture.

Fidelity is intentional and byte-level where it is observable by the model: the system and
instance prompts, the `bash` tool schema, tool-call parsing and its format-error messages, the
JSON observation format (including the ≥10000-character truncation and jinja `tojson`'s
HTML-safe/ensure-ASCII escaping), the `COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT` submission
protocol, and the step / consecutive-format-error limits.

The one adaptation is the environment: mini runs each command in a persistent working
directory; here the working directory is snapshotted into a `Cas.Store` after every command, so
the environment is a content-addressed value (`Cas.Hash`) that can be branched and replayed —
exactly the `Dialogue × Env` state from `Alaya.Agent`. Where the commands run is an `Executor`:
on the host, or (see `Alaya.Agent.MiniSwe.Docker`) in a container with that same directory
bind-mounted, which changes nothing about what a state is. The commands themselves run
identically:
an `exec /bin/sh -c "$@" 2>&1` trampoline reproduces `Popen(command, shell=True,
stderr=STDOUT)` byte-for-byte (the inner shell sees exactly mini's argv, so error messages and
line numbers match; stderr is merged at the fd level; stdin is inherited), with the inherited
environment plus overrides, CPython's lossy `errors="replace"` UTF-8 decoding of the output,
and a `setsid` timeout that kills the whole process group. Like mini, every failure to execute
— an unparseable tool-call `arguments` string, a non-string `command`, a spawn error — becomes
a format-error turn or an exception observation, never a crashed run.

Deviations are limited to the wire envelope our shared `ChatCompletions` provider always sends
(an explicit `tool_choice: auto`, `response_format: text`, and a temperature), none of which the
model's behavior depends on; per-model cost accounting (litellm pricing), which is omitted, so
`cost_limit` is not enforced; and the detail text inside two rare messages, where mini embeds a
Python error string this port cannot reproduce: JSON parse errors in tool arguments carry
Lean's parser message (not `json.JSONDecodeError`'s), and spawn failures carry Lean's
`IO.Error` text (not Python's exception text). `tojson`'s `ensure_ascii` uses `\uXXXX`;
non-ASCII bytes match, astral characters are emitted as surrogate pairs.

One further deviation applies only to the container executor: mini's environment persists
everything a command does, while a snapshot captures only the working directory, so changes
outside it (installed packages, `/tmp`) live as long as the run but are not part of a state and
are gone when a branch is resumed later.
-/

namespace Alaya.Agent.MiniSwe

open Alaya (Result Error)
open Alaya.Agent (Dialogue Outcome)

/-! ## Configuration -/

structure Config where
  task : String
  /-- Maximum model calls; 0 disables the limit (as in mini.yaml). -/
  stepLimit : Nat := 0
  /-- Consecutive format errors tolerated before exiting; 0 disables. -/
  maxConsecutiveFormatErrors : Nat := 3
  /-- Per-command wall-clock timeout in seconds. -/
  timeoutSeconds : Nat := 30
  /-- Environment overrides layered onto the inherited environment (mini's defaults). -/
  env : Array (String × String) := #[
    ("PAGER", "cat"), ("MANPAGER", "cat"), ("LESS", "-R"),
    ("PIP_PROGRESS_BAR", "off"), ("TQDM_DISABLE", "1")]
  deriving Inhabited

/-! ## Prompts (rendered `mini.yaml` templates)

These are the exact strings jinja produces from `mini.yaml`; the only variable parts are the
task and the `uname` system-information line. jinja strips one trailing newline, so none of
these end in `\n`. -/

def systemMessage : String :=
  "You are a helpful assistant that can interact with a computer."

private def instanceMiddle : String :=
  "\n\nYou can execute bash commands and edit files to implement the necessary changes.\n\n## Recommended Workflow\n\nThis workflow should be done step-by-step so that you can iterate on your changes and any possible problems.\n\n1. Analyze the codebase by finding and reading relevant files\n2. Create a script to reproduce the issue\n3. Edit the source code to resolve the issue\n4. Verify your fix works by running your script again\n5. Test edge cases to ensure your fix is robust\n6. Submit your changes and finish your work by issuing the following command: `echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT`.\n   Do not combine it with any other command. <important>After this command, you cannot continue working on this task.</important>\n\n## Command Execution Rules\n\nYou are operating in an environment where\n\n1. You issue at least one command\n2. The system executes the command(s) in a subshell\n3. You see the result(s)\n4. You write your next command(s)\n\nEach response should include:\n\n1. **Reasoning text** where you explain your analysis and plan\n2. At least one tool call with your command\n\n**CRITICAL REQUIREMENTS:**\n\n- Your response SHOULD include reasoning text explaining what you're doing\n- Your response MUST include AT LEAST ONE bash tool call\n- Directory or environment variable changes are not persistent. Every action is executed in a new subshell.\n- However, you can prefix any action with `MY_ENV_VAR=MY_VALUE cd /path/to/working/dir && ...` or write/load environment variables from files\n- Submit your changes and finish your work by issuing the following command: `echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT`.\n  Do not combine it with any other command. <important>After this command, you cannot continue working on this task.</important>\n\nExample of a CORRECT response:\n<example_response>\nI need to understand the structure of the repository first. Let me check what files are in the current directory to get a better understanding of the codebase.\n\n[Makes bash tool call with {\"command\": \"ls -la\"} as arguments]\n</example_response>\n\n<system_information>\n"

private def instanceSuffixDarwin : String :=
  "\n</system_information>\n\n## Useful command examples\n\n### Create a new file:\n\n```bash\ncat <<'EOF' > newfile.py\nimport numpy as np\nhello = \"world\"\nprint(hello)\nEOF\n```\n\n### Edit files with sed:<important>\nYou are on MacOS. For all the below examples, you need to use `sed -i ''` instead of `sed -i`.\n</important>```bash\n# Replace all occurrences\nsed -i 's/old_string/new_string/g' filename.py\n\n# Replace only first occurrence\nsed -i 's/old_string/new_string/' filename.py\n\n# Replace first occurrence on line 1\nsed -i '1s/old_string/new_string/' filename.py\n\n# Replace all occurrences in lines 1-10\nsed -i '1,10s/old_string/new_string/g' filename.py\n```\n\n### View file content:\n\n```bash\n# View specific lines with numbers\nnl -ba filename.py | sed -n '10,20p'\n```\n\n### Any other command you want to run\n\n```bash\nanything\n```"

private def instanceSuffixOther : String :=
  "\n</system_information>\n\n## Useful command examples\n\n### Create a new file:\n\n```bash\ncat <<'EOF' > newfile.py\nimport numpy as np\nhello = \"world\"\nprint(hello)\nEOF\n```\n\n### Edit files with sed:```bash\n# Replace all occurrences\nsed -i 's/old_string/new_string/g' filename.py\n\n# Replace only first occurrence\nsed -i 's/old_string/new_string/' filename.py\n\n# Replace first occurrence on line 1\nsed -i '1s/old_string/new_string/' filename.py\n\n# Replace all occurrences in lines 1-10\nsed -i '1,10s/old_string/new_string/g' filename.py\n```\n\n### View file content:\n\n```bash\n# View specific lines with numbers\nnl -ba filename.py | sed -n '10,20p'\n```\n\n### Any other command you want to run\n\n```bash\nanything\n```"

/-- The rendered instance (task) message. `system`/`release`/`version`/`machine` are the
`uname` fields; the MacOS `sed` note is included exactly when `system == "Darwin"`. -/
def instanceMessage (task system release version machine : String) : String :=
  "Please solve this issue: " ++ task ++ instanceMiddle ++
    system ++ " " ++ release ++ " " ++ version ++ " " ++ machine ++
    (if system == "Darwin" then instanceSuffixDarwin else instanceSuffixOther)

/-- The `bash` tool, serialized byte-for-byte as mini's `BASH_TOOL`. -/
def bashTool : Chat.ToolDefinition := {
  name := "bash"
  description := "Execute a bash command"
  parameters := .object #[("command", .string (description? := some "The bash command to execute"))]
  parametersJson? := some <| .mkObj [
    ("type", "object"),
    ("properties", .mkObj [
      ("command", .mkObj [("type", "string"), ("description", "The bash command to execute")])]),
    ("required", .arr #[("command" : Lean.Json)])]
}

/-! ## jinja `tojson` string encoding

`tojson` is `htmlsafe_json_dumps`: `json.dumps(ensure_ascii=True)` followed by escaping of
`<`, `>`, `&`, `'`. We reproduce it exactly so observations are byte-identical. -/

private def hex4 (n : Nat) : String :=
  let digit (shift : Nat) : Char :=
    let v := (n >>> shift) % 16
    if v < 10 then Char.ofNat (48 + v) else Char.ofNat (87 + v)
  String.ofList [digit 12, digit 8, digit 4, digit 0]

private def escapeChar (c : Char) : String :=
  let n := c.toNat
  if c == '\"' then "\\\""
  else if c == '\\' then "\\\\"
  else if c == '\n' then "\\n"
  else if c == '\r' then "\\r"
  else if c == '\t' then "\\t"
  else if n == 8 then "\\b"
  else if n == 12 then "\\f"
  else if c == '<' then "\\u003c"
  else if c == '>' then "\\u003e"
  else if c == '&' then "\\u0026"
  else if c == '\'' then "\\u0027"
  else if n < 0x20 then "\\u" ++ hex4 n
  else if n < 0x80 then String.singleton c
  else if n <= 0xFFFF then "\\u" ++ hex4 n
  else
    let cp := n - 0x10000
    "\\u" ++ hex4 (0xD800 + (cp >>> 10)) ++ "\\u" ++ hex4 (0xDC00 + (cp % 0x400))

/-- JSON-encodes a string exactly as jinja's `tojson`, including surrounding quotes. -/
def jsonString (s : String) : String :=
  "\"" ++ String.join (s.toList.map escapeChar) ++ "\""

/-! ## Command output and observations -/

/-- The result of executing one command, matching mini's environment output dict. -/
structure Output where
  output : String
  returncode : Int
  exceptionInfo : String := ""
  deriving Repr, Inhabited

/-- Renders an execution result as the tool message content, reproducing `mini.yaml`'s
`observation_template` (the tool-calling variant) byte-for-byte. -/
def observation (o : Output) : String :=
  let excPart :=
    if o.exceptionInfo != "" then ", \"exception_info\": " ++ jsonString o.exceptionInfo else ""
  let length := o.output.length
  if length < 10000 then
    "{\n  \"returncode\": " ++ toString o.returncode ++
      ",\n  \"output\": " ++ jsonString o.output ++ excPart ++ "\n}"
  else
    let head := String.ofList (o.output.toList.take 5000)
    let tail := String.ofList (o.output.toList.drop (length - 5000))
    "{\n  \"returncode\": " ++ toString o.returncode ++
      ",\n  \"output_head\": " ++ jsonString head ++
      ",\n  \"output_tail\": " ++ jsonString tail ++
      ",\n  \"elided_chars\": " ++ toString (length - 10000) ++
      ",\n  \"warning\": \"Output too long.\"" ++ excPart ++ "\n}"

/-! ## Action parsing and format errors -/

/-- Reproduces `mini.yaml`'s `format_error_template`: a truncation notice when the provider
signalled a cut-off, otherwise the tool-call formatting guidance wrapping `error`. -/
def formatErrorMessage (error : String) (hasToolCalls : Bool) (finishReason? : Option String) : String :=
  let truncated := match finishReason? with
    | some "length" => true
    | some "tool_calls" => !hasToolCalls
    | _ => false
  if truncated then
    "Your previous response reached the output token limit (finish_reason=" ++
      finishReason?.getD "" ++
      ") before you produced a tool call, so it was cut off. Respond more concisely and finish " ++
      "with exactly one bash tool call. If you need to think more, do so briefly."
  else
    "Tool call error:\n\n<error>\n" ++ error ++ "\n</error>\n\n" ++
    "Here is general guidance on how to submit correct toolcalls:\n\n" ++
    "Every response needs to use the 'bash' tool at least once to execute commands.\n\n" ++
    "Call the bash tool with your command as the argument:\n" ++
    "- Tool: bash\n- Arguments: {\"command\": \"your_command_here\"}\n\n" ++
    "If you want to end the task, please issue the following command: " ++
    "`echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT`\nwithout any other command."

/-- Parsed model turn: a list of `(tool_call_id, command)` actions — the command is the raw
JSON value of the `command` argument, as in mini's action dict — or a format-error message to
send back as a user turn. -/
inductive Parsed where
  | actions (calls : Array (String × Lean.Json))
  | formatError (message : String)

/-- Parses a response's tool calls exactly as `parse_toolcall_actions`: every call must carry
arguments that parse as JSON, name `bash`, and have a `command`; the first offender produces
the format error. The error messages concatenate as in mini, where unparseable arguments read
as `{}` and so also trigger the missing-command message. -/
def parseActions (response : Chat.Response) : Parsed := Id.run do
  if response.toolCalls.isEmpty then
    return .formatError <| formatErrorMessage
      "No tool calls found in the response. Every response MUST include at least one tool call."
      false response.finishReason?
  let mut actions : Array (String × Lean.Json) := #[]
  for call in response.toolCalls do
    let mut error := ""
    if let some raw := call.invalidArguments? then
      let detail := match Lean.Json.parse raw with
        | .error e => e
        | .ok _ => "invalid JSON"
      error := "Error parsing tool call arguments: " ++ detail ++ "."
    if call.name != "bash" then error := error ++ "Unknown tool '" ++ call.name ++ "'."
    let command? := if call.invalidArguments?.isSome then none
      else (call.arguments.getObjVal? "command").toOption
    if command?.isNone then error := error ++ "Missing 'command' argument in bash tool call."
    if error != "" then
      return .formatError (formatErrorMessage error.trimAscii.toString true response.finishReason?)
    actions := actions.push (call.id, command?.getD .null)
  return .actions actions

/-! ## Submission detection -/

/-- Python `str.strip` whitespace (CPython `unicodeobject.c`): the ASCII whitespace plus
`\x1c`–`\x1f`, NEL, NBSP, and the Unicode space separators. -/
private def pythonIsSpace (c : Char) : Bool :=
  let n := c.toNat
  (0x09 <= n && n <= 0x0d) || (0x1c <= n && n <= 0x1f) || n == 0x20 || n == 0x85 ||
    n == 0xa0 || n == 0x1680 || (0x2000 <= n && n <= 0x200a) || n == 0x2028 || n == 0x2029 ||
    n == 0x202f || n == 0x205f || n == 0x3000

/-- Python `str.splitlines` line boundaries, minus `\r\n`, which is handled as a unit. -/
private def pythonIsLineBreak (c : Char) : Bool :=
  let n := c.toNat
  (0x0a <= n && n <= 0x0d) || (0x1c <= n && n <= 0x1e) || n == 0x85 || n == 0x2028 || n == 0x2029

private def pythonStrip (s : List Char) : String :=
  String.ofList ((s.dropWhile pythonIsSpace).reverse.dropWhile pythonIsSpace).reverse

/-- Splits off the first `str.splitlines` line: its content, and everything after its line
ending — which is `"".join(lines[1:])` of a `keepends=True` split. -/
private def splitFirstLine (acc : List Char) : List Char -> List Char × List Char
  | [] => (acc.reverse, [])
  | '\r' :: '\n' :: rest => (acc.reverse, rest)
  | c :: rest =>
    if pythonIsLineBreak c then (acc.reverse, rest) else splitFirstLine (c :: acc) rest

/-- Detects mini's submission sentinel exactly as `LocalEnvironment._check_finished`: the first
`splitlines` line of the left-stripped output, stripped, is
`COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT` and the command succeeded. The submission is everything
after that first line. -/
def submission? (output : String) (returncode : Int) : Option String :=
  if returncode != 0 then none
  else
    let (first, rest) := splitFirstLine [] (output.toList.dropWhile pythonIsSpace)
    if pythonStrip first == "COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT"
    then some (String.ofList rest)
    else none

/-! ## Environment: Cas-backed command execution -/

/-- The `uname` fields `instanceMessage` is built from, read from wherever commands actually run
— the host for a local executor, the image for a container one. Getting this from the wrong
place tells the model it is on another operating system, and (for `Darwin`) hands it the BSD
`sed` note, so it is part of the executor rather than something the prompt looks up itself. -/
structure Uname where
  system : String
  release : String
  version : String
  machine : String
  deriving Repr, Inhabited, BEq

/-- Where the agent's commands run. The workspace is always the host directory the runtime
snapshots — a container gets it bind-mounted — so the executor never changes what a state *is*:
everything outside that directory is disposable either way. -/
structure Executor where
  /-- Runs mini's inner argv in `workDir` with stderr merged, as `Popen(shell=True)` would.
  `display` is the command as it appears in messages. Like mini, a failure to execute is an
  observation with `exceptionInfo`, never a raised error. -/
  exec : (workDir : System.FilePath) -> (argv : Array String) -> (display : String) -> IO Output
  /-- `uname` where the commands run. -/
  uname : IO Uname
  /-- The pinned image commands run in, recorded in the trajectory; `none` on the host. -/
  image? : Option String := none
  /-- Releases what the executor holds — a container, say — at the end of a run. -/
  close : IO Unit := pure ()

/-- The live run: the model stack, the store holding every durable artefact, the working
directory holding none, and the executor that runs commands in it. -/
structure Runtime where
  model : Model
  /-- Where everything durable lives. Written only through the content-addressed store's own
  API; the agent never sees this path. -/
  store : Cas.Store
  /-- Where the agent runs its commands. Wiped and re-materialized from a snapshot at every
  checkout, so nothing here survives a turn that is not first captured into `store`. -/
  workDir : System.FilePath
  /-- How commands run: on the host, or in a container with `workDir` bind-mounted. -/
  executor : Executor
  config : Config

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

/-- Decodes UTF-8 exactly as CPython's `errors="replace"` (mini's output decoding): each
maximal subpart of an ill-formed sequence becomes one U+FFFD. -/
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

/-- Python type name of a JSON value, as `json.loads` produces it. -/
private def pythonTypeName : Lean.Json -> String
  | .null => "NoneType"
  | .bool _ => "bool"
  | .num n => if n.exponent == 0 then "int" else "float"
  | .str _ => "str"
  | .arr _ => "list"
  | .obj _ => "dict"

/-- Python `repr` of a JSON value (approximate string escaping), for the timeout message when
mini's command is not a string. -/
private partial def pythonRepr : Lean.Json -> String
  | .null => "None"
  | .bool b => if b then "True" else "False"
  | .num n => toString n
  | .str s => "'" ++ ((s.replace "\\" "\\\\").replace "'" "\\'") ++ "'"
  | .arr elems => "[" ++ ", ".intercalate (elems.toList.map pythonRepr) ++ "]"
  | .obj kvs => "{" ++ ", ".intercalate
      (kvs.foldl (fun acc k v => acc ++ [pythonRepr (.str k) ++ ": " ++ pythonRepr v]) []) ++ "}"

/-- The inner `/bin/sh -c` argv that mini's `Popen(command, shell=True)` builds for a `command`
value, with its display form for the timeout message — or the `TypeError` text CPython raises.
A string is the script; Popen's `list(...)` splices a list into extra shell arguments and a
dict into its keys; other types are not iterable. -/
private def shellArgv : Lean.Json -> Except String (Array String × String)
  | .str s => .ok (#[s], s)
  | .arr elems => do
    let args ← elems.mapM fun
      | .str s => pure s
      | other => throw ("expected str, bytes or os.PathLike object, not " ++ pythonTypeName other)
    pure (args, pythonRepr (.arr elems))
  | .obj kvs => .ok (kvs.foldl (fun acc k _ => acc.push k) #[], pythonRepr (.obj kvs))
  | other => .error ("'" ++ pythonTypeName other ++ "' object is not iterable")

private partial def pollExit (tryWait : IO (Option UInt32)) (kill : IO Unit) (wait : IO UInt32)
    (readAll : IO String) (deadlineMs timeoutSeconds : Nat) (command : String) : IO Output := do
  match ← tryWait with
  | some code => pure { output := ← readAll, returncode := Int.ofNat code.toNat }
  | none =>
    if (← IO.monoMsNow) >= deadlineMs then
      kill
      let _ ← wait
      pure {
        output := ← readAll, returncode := -1
        exceptionInfo := "An error occurred while executing the command: Command '" ++
          command ++ "' timed out after " ++ toString timeoutSeconds ++ " seconds" }
    else
      IO.sleep 20
      pollExit tryWait kill wait readAll deadlineMs timeoutSeconds command

/-- The inner argv mini's `Popen(command, shell=True)` runs, wrapped in the trampoline that
merges stderr into stdout at the fd level and then execs exactly that argv, so shell error
messages and line numbers are byte-identical. Every executor uses it, so a container changes
where the command runs and nothing about what it sees. -/
def trampoline (argv : Array String) : Array String :=
  #["-c", "exec /bin/sh -c \"$@\" 2>&1", "sh"] ++ argv

/-- `uname` on the host, for the local executor. -/
def Uname.local : IO Uname := do
  let field (flag : String) : IO String := do
    pure (← IO.Process.output { cmd := "uname", args := #[flag] }).stdout.trimAscii.toString
  pure { system := ← field "-s", release := ← field "-r"
         version := ← field "-v", machine := ← field "-m" }

/-- Runs commands on the host, exactly like mini's `LocalEnvironment`: in the working directory
with the inherited environment plus overrides, stdin inherited, in a fresh session so a timeout
kills the whole process group. Spawn failures become exception observations, as mini catches
every `Popen` error. -/
def Executor.local (config : Config) : Executor where
  uname := Uname.local
  exec := fun workDir argv display => do
    -- Popen raises before running when `cwd` is unusable; Lean's spawn instead exits 255 from
    -- the child, so the check happens here, with CPython's error text.
    if !(← workDir.isDir) then
      let error := if (← workDir.pathExists)
        then s!"[Errno 20] Not a directory: '{workDir}'"
        else s!"[Errno 2] No such file or directory: '{workDir}'"
      return { output := "", returncode := -1,
               exceptionInfo := s!"An error occurred while executing the command: {error}" }
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
      pure { output := "", returncode := -1,
             exceptionInfo := s!"An error occurred while executing the command: {e}" }

/-- Opens a store and working directory for a run. `storeRoot` must be outside `workDir`, which
is destroyed and rebuilt on every checkout. Commands run on the host unless given an executor. -/
def Runtime.create (model : Model) (config : Config)
    (workDir storeRoot : System.FilePath) (executor : Executor := Executor.local config) :
    Result Runtime := do
  let store ← Cas.Store.create storeRoot
  Result.fromIO Error.storage (IO.FS.createDirAll workDir)
  pure { model, store, workDir, executor, config }

/-- Runs one shell invocation where the runtime's executor puts it. -/
def execShell (rt : Runtime) (argv : Array String) (display : String) : IO Output :=
  rt.executor.exec rt.workDir argv display

/-- Runs one string command (the common case of `execCommand`). -/
def execBash (rt : Runtime) (command : String) : IO Output :=
  execShell rt #[command] command

/-- Executes mini's `command` value, whatever its type: strings run as shell scripts, and
Popen's accidental treatment of other JSON types is reproduced (lists splice into shell
arguments, dicts contribute their keys, anything else is a `TypeError` observation). -/
def execCommand (rt : Runtime) (command : Lean.Json) : IO Output :=
  match shellArgv command with
  | .ok (argv, display) => execShell rt argv display
  | .error typeError =>
    pure { output := "", returncode := -1,
           exceptionInfo := "An error occurred while executing the command: " ++ typeError }

/-- Executes one command and snapshots the working directory, returning the observation output
and the new environment address. -/
def step (rt : Runtime) (command : Lean.Json) : Result (Output × Cas.Hash) := do
  let output ← Result.fromIO Error.storage (execCommand rt command)
  let snapshot ← rt.store.snapshot rt.workDir
  pure (output, snapshot)

/-! ## The three primitives and the run loop -/

/-- The stochastic primitive: one model turn with the `bash` tool available. -/
def sample (rt : Runtime) (dialogue : Dialogue) : Result Chat.Response := do
  let stream ← rt.model.sample { messages := dialogue, tools := #[bashTool] }
  stream.next

private def assistantOf (response : Chat.Response) : Chat.Message :=
  .assistant response.content? response.toolCalls

/-- The initial two-message dialogue (system + task). `uname` is passed in rather than looked up
here because it describes where the commands will run, which is the executor's business, and
because this dialogue is frozen into the root state at creation time. -/
def initialDialogue (config : Config) (uname : Uname) : Dialogue :=
  #[.system systemMessage,
    .user (instanceMessage config.task uname.system uname.release uname.version uname.machine)]

/-- The exact mini control loop over `Dialogue × Cas.Hash`. Mirrors `DefaultAgent.run`:
limits are checked before each model call; a format error is appended as a user turn (the
offending assistant turn is dropped) and exits after too many in a row; a submission or a step
limit ends the run. -/
private partial def loop (rt : Runtime) (dialogue : Dialogue) (env : Cas.Hash)
    (nCalls consecutiveFormatErrors : Nat) : Result (Dialogue × Cas.Hash × Outcome) := do
  if rt.config.stepLimit > 0 && nCalls >= rt.config.stepLimit then
    return (dialogue, env, { status := "LimitsExceeded" })
  let response ← sample rt dialogue
  let nCalls := nCalls + 1
  match parseActions response with
  | .formatError message =>
    let consecutiveFormatErrors := consecutiveFormatErrors + 1
    let dialogue := dialogue.push (.user message)
    if rt.config.maxConsecutiveFormatErrors > 0 &&
        consecutiveFormatErrors >= rt.config.maxConsecutiveFormatErrors then
      return (dialogue, env, { status := "RepeatedFormatError" })
    loop rt dialogue env nCalls consecutiveFormatErrors
  | .actions actions =>
    let dialogue := dialogue.push (assistantOf response)
    let mut env := env
    let mut observations : Array Chat.Message := #[]
    let mut submitted : Option Outcome := none
    for (id, command) in actions do
      if submitted.isNone then
        let (output, env') ← step rt command
        env := env'
        match submission? output.output output.returncode with
        | some sub => submitted := some { status := "Submitted", submission := sub }
        | none => observations := observations.push (.tool id (.str (observation output)))
    match submitted with
    | some outcome => return (dialogue, env, outcome)
    | none => loop rt (dialogue ++ observations) env nCalls 0

/-- Runs the agent to completion, returning the final dialogue, the final environment snapshot,
and the outcome. -/
def run (rt : Runtime) : Result (Dialogue × Cas.Hash × Outcome) := do
  let dialogue := initialDialogue rt.config (← Result.fromIO Error.configuration rt.executor.uname)
  let env ← rt.store.snapshot rt.workDir
  loop rt dialogue env 0 0

/-- The three primitives packaged as a generic `Agent`, for reuse and to make the structure
explicit. `next` selects sample-vs-act from unanswered tool calls; submission and limits, which
are not functions of the dialogue alone, are handled by `run`. -/
def agent (rt : Runtime) : Alaya.Agent.Agent Cas.Hash := {
  sample := sample rt
  act := fun call _env => do
    let command := if call.invalidArguments?.isSome then .str ""
      else (call.arguments.getObjVal? "command").toOption.getD (.str "")
    let (output, env') ← step rt command
    pure (.tool call.id (.str (observation output)), env')
  next := fun dialogue =>
    match dialogue.back? with
    | some (.assistant _ calls) =>
      match calls[0]? with
      | some call => .act call
      | none => .done { status := "Completed" }
    | _ => .sample
}

end Alaya.Agent.MiniSwe
