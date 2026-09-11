import Alaya.Agent
import Alaya.Executor

/-!
A port of mini-SWE-agent's default tool-calling agent (`mini.yaml` + `litellm_model` +
`actions_toolcall`) as an `Alaya.Agent.Agent`. See `docs/miniswe.md`.

Fidelity is intentional and byte-level where it is observable by the model: the system and
instance prompts, the `bash` tool schema, tool-call parsing and its format-error messages, the
JSON observation format (including the ≥10000-character truncation and jinja `tojson`'s
HTML-safe/ensure-ASCII escaping), and the step / consecutive-format-error limits.

Three adaptations, the first two forced by the split between what is recorded and what is shown:

* **Ending a run is a tool call.** Mini ends a run when a command prints the sentinel
  `COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT` on its first line — its environment scans every
  command's output for it. Here the agent calls a `submit` tool instead, so the driver never has
  to read a tool's output to know the run is over. The two sentences of the prompt that name the
  sentinel change accordingly (`miniSubmitInstruction` → `submitInstruction`), and so does the
  last line of the format-error message.
* **Tool schemas are strict.** `JsonSchema` serializes every object with all properties
  required and `"additionalProperties": false`, so the `bash` schema the model sees carries that
  one extra key mini's does not.
* **The environment is a snapshot.** Mini runs each command in a persistent working directory;
  here the directory is snapshotted after every command by the trajectory, so a state can be
  branched and replayed. Where the commands run is an `Alaya.Executor`; the commands themselves
  run identically (see that module), and, as in mini, every failure to execute — an unparseable
  tool-call `arguments` string, a non-string `command`, a spawn error — becomes a format-error
  turn or an exception observation, never a crashed run.

Deviations are otherwise limited to the wire envelope the shared provider always sends (an
explicit `tool_choice: auto`, `response_format: text`, and a temperature), none of which the
model's behavior depends on; per-model cost accounting (litellm pricing), which is omitted, so
`cost_limit` is not enforced; and the detail text inside two rare messages, where mini embeds a
Python error string this port cannot reproduce: JSON parse errors in tool arguments carry Lean's
parser message (not `json.JSONDecodeError`'s), and spawn failures carry Lean's `IO.Error` text
(not Python's exception text). `tojson`'s `ensure_ascii` uses `\uXXXX`; non-ASCII bytes match,
astral characters are emitted as surrogate pairs.
-/

namespace Alaya.Agent.MiniSwe

open Alaya (Result Error Output Executor Uname)
open Alaya.Agent (Agent Event Log Dialogue Outcome Directive)

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

/-- How this agent's commands are run. -/
def Config.executor (config : Config) : Executor.Config :=
  { timeoutSeconds := config.timeoutSeconds, env := config.env }

/-! ## Prompts (rendered `mini.yaml` templates)

These are the exact strings jinja produces from `mini.yaml`, except for the sentences that name
the submission sentinel, which name the `submit` tool instead. The only variable parts are the
task and the `uname` system-information line. jinja strips one trailing newline, so none of
these end in `\n`. -/

def systemMessage : String :=
  "You are a helpful assistant that can interact with a computer."

/-- Mini's instruction for ending a run, as it appears twice in the instance prompt with two
different continuation indents. -/
def miniSubmitInstruction (indent : String) : String :=
  "Submit your changes and finish your work by issuing the following command: `echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT`.\n" ++
  indent ++ "Do not combine it with any other command. <important>After this command, you cannot continue working on this task.</important>"

/-- The port's instruction in its place. -/
def submitInstruction (indent : String) : String :=
  "Submit your changes and finish your work by calling the `submit` tool.\n" ++
  indent ++ "Do not combine it with any other tool call. <important>After this call, you cannot continue working on this task.</important>"

private def instanceMiddle : String :=
  "\n\nYou can execute bash commands and edit files to implement the necessary changes.\n\n## Recommended Workflow\n\nThis workflow should be done step-by-step so that you can iterate on your changes and any possible problems.\n\n1. Analyze the codebase by finding and reading relevant files\n2. Create a script to reproduce the issue\n3. Edit the source code to resolve the issue\n4. Verify your fix works by running your script again\n5. Test edge cases to ensure your fix is robust\n6. " ++ submitInstruction "   " ++ "\n\n## Command Execution Rules\n\nYou are operating in an environment where\n\n1. You issue at least one command\n2. The system executes the command(s) in a subshell\n3. You see the result(s)\n4. You write your next command(s)\n\nEach response should include:\n\n1. **Reasoning text** where you explain your analysis and plan\n2. At least one tool call with your command\n\n**CRITICAL REQUIREMENTS:**\n\n- Your response SHOULD include reasoning text explaining what you're doing\n- Your response MUST include AT LEAST ONE bash tool call\n- Directory or environment variable changes are not persistent. Every action is executed in a new subshell.\n- However, you can prefix any action with `MY_ENV_VAR=MY_VALUE cd /path/to/working/dir && ...` or write/load environment variables from files\n- " ++ submitInstruction "  " ++ "\n\nExample of a CORRECT response:\n<example_response>\nI need to understand the structure of the repository first. Let me check what files are in the current directory to get a better understanding of the codebase.\n\n[Makes bash tool call with {\"command\": \"ls -la\"} as arguments]\n</example_response>\n\n<system_information>\n"

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

/-- The opening log of a run: the system prompt and the task. `uname` is passed in because it
describes where the commands will run, which is the executor's business, and because this log
is frozen into the root state at creation time. -/
def initialLog (config : Config) (uname : Uname) : Log :=
  #[.message (.system systemMessage),
    .message (.user (instanceMessage config.task uname.system uname.release uname.version uname.machine))]

/-! ## Tools -/

/-- The `bash` tool: mini's `BASH_TOOL`, serialized in strict mode. The one visible difference
from mini's JSON is the `"additionalProperties": false` every strict object carries. -/
def bashTool : Chat.ToolDefinition := {
  name := "bash"
  description := "Execute a bash command"
  parameters := .object #[("command", .string (description? := some "The bash command to execute"))]
}

/-- The tool that ends a run, in place of mini's output sentinel. `message` is required, so the
model always says what it did; it becomes the run's submission. -/
def submitTool : Chat.ToolDefinition := {
  name := "submit"
  description := "Finish the task. Call this once your changes are complete; nothing runs after it."
  parameters := .object #[("message", .string (description? := some "A short summary of what you did"))]
}

/-- The tools offered on every sample. -/
def tools : Array Chat.ToolDefinition := #[bashTool, submitTool]

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

/-! ## The view of an observation -/

/-- Renders an execution result as the tool message content, reproducing `mini.yaml`'s
`observation_template` (the tool-calling variant) byte-for-byte: the whole output under 10000
characters, otherwise its first and last 5000 with a count of what was left out. -/
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

/-- The last line of mini's format-error message, which names the sentinel. -/
def miniEndHint : String :=
  "If you want to end the task, please issue the following command: " ++
  "`echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT`\nwithout any other command."

/-- The port's last line in its place. -/
def endHint : String :=
  "If you want to end the task, call the `submit` tool\nwithout any other tool call."

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
    "- Tool: bash\n- Arguments: {\"command\": \"your_command_here\"}\n\n" ++ endHint

/-- One parsed tool call. A `bash` action carries the raw JSON value of its `command` argument,
as mini's action dict does; `submit` ends the run. -/
inductive Action where
  | bash (id : String) (command : Lean.Json)
  | submit (id : String) (message : String)
  deriving Inhabited

def Action.id : Action -> String
  | .bash id _ => id
  | .submit id _ => id

/-- A parsed model turn: its actions, or a format-error message to send back as a user turn. -/
inductive Parsed where
  | actions (actions : Array Action)
  | formatError (message : String)

/-- Parses a response's tool calls exactly as `parse_toolcall_actions`: every call must carry
arguments that parse as JSON, name a known tool, and (for `bash`) have a `command`; the first
offender produces the format error. The error messages concatenate as in mini, where
unparseable arguments read as `{}` and so also trigger the missing-command message. -/
def parseActions (response : Chat.Response) : Parsed := Id.run do
  if response.toolCalls.isEmpty then
    return .formatError <| formatErrorMessage
      "No tool calls found in the response. Every response MUST include at least one tool call."
      false response.finishReason?
  let mut actions : Array Action := #[]
  for call in response.toolCalls do
    let mut error := ""
    if let some raw := call.invalidArguments? then
      let detail := match Lean.Json.parse raw with
        | .error e => e
        | .ok _ => "invalid JSON"
      error := "Error parsing tool call arguments: " ++ detail ++ "."
    if call.name == "submit" then
      if error != "" then
        return .formatError (formatErrorMessage error.trimAscii.toString true response.finishReason?)
      let message := match call.arguments.getObjVal? "message" with
        | .ok (.str s) => s
        | _ => ""
      actions := actions.push (.submit call.id message)
      continue
    if call.name != "bash" then error := error ++ "Unknown tool '" ++ call.name ++ "'."
    let command? := if call.invalidArguments?.isSome then none
      else (call.arguments.getObjVal? "command").toOption
    if command?.isNone then error := error ++ "Missing 'command' argument in bash tool call."
    if error != "" then
      return .formatError (formatErrorMessage error.trimAscii.toString true response.finishReason?)
    actions := actions.push (.bash call.id (command?.getD .null))
  return .actions actions

/-! ## Running a command value as Popen would -/

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

/-- Executes mini's `command` value, whatever its type: strings run as shell scripts, and
Popen's accidental treatment of other JSON types is reproduced (lists splice into shell
arguments, dicts contribute their keys, anything else is a `TypeError` observation). -/
def execCommand (executor : Executor) (workDir : System.FilePath) (command : Lean.Json) :
    IO Output :=
  match shellArgv command with
  | .ok (argv, display) => executor.exec workDir argv display
  | .error typeError => pure (Executor.failed typeError)

/-! ## The agent: view, control, action -/

/-- Mini's projection of the log onto the dialogue, event by event: a message as it is; a
response as the assistant turn it was, unless it failed to parse, in which case mini drops it
and shows the format error as a user turn instead; an observation as the JSON envelope, which
is where the ≥10000-character truncation happens. The record keeps the whole output; only the
model sees the cut. -/
def view (log : Log) : Dialogue :=
  log.map fun
    | .message m => m
    | .response r =>
      match parseActions r with
      | .actions _ => .assistant r.content? r.toolCalls r.reasoning?
      | .formatError message => .user message
    | .observation id content =>
      let text := match Output.fromJson? content with
        | some output => observation output
        | none => match content with | .str s => s | other => other.compress
      .tool id (.str text)

/-- How many format-error responses end the log, with no clean turn between them — mini's
`n_consecutive_format_errors`. A person's message in between does not reset it; an observation
does, since it means a turn ran. -/
private def trailingFormatErrors (log : Log) : Nat := Id.run do
  let mut count := 0
  for event in log.reverse do
    match event with
    | .response r =>
      match parseActions r with
      | .formatError _ => count := count + 1
      | .actions _ => return count
    | .observation _ _ => return count
    | .message _ => pure ()
  return count

/-- Mini's control flow, decided from the log. Mirrors `DefaultAgent.run`: limits are checked
before each model call; after a format error the run continues (the view shows the error) or
exits after too many in a row; a turn's actions run in order until a `submit` ends the run. -/
def next (config : Config) (log : Log) : Directive :=
  let sampleOrStop : Directive :=
    if config.stepLimit > 0 && log.responses >= config.stepLimit
    then .done { status := "LimitsExceeded" } else .sample
  match log.lastResponse? with
  | none => sampleOrStop
  | some response =>
    match parseActions response with
    | .formatError _ =>
      if config.maxConsecutiveFormatErrors > 0 &&
          trailingFormatErrors log >= config.maxConsecutiveFormatErrors
      then .done { status := "RepeatedFormatError" }
      else sampleOrStop
    | .actions actions =>
      let pending := log.pending
      match actions.find? (fun action => pending.any (·.id == action.id)) with
      | none => sampleOrStop
      | some (.submit _ message) => .done { status := "Submitted", submission := message }
      | some (.bash id _) =>
        match pending.find? (·.id == id) with
        | some call => .act call
        | none => sampleOrStop

/-- Runs one `bash` call through the executor and records mini's output dict. -/
def act (executor : Executor) (workDir : System.FilePath) (call : Chat.ToolCall) :
    Result Lean.Json := do
  if call.name != "bash" then
    throw <| .configuration s!"mini has no tool named {call.name} to run"
  let command := (call.arguments.getObjVal? "command").toOption.getD .null
  let output ← Result.fromIO Error.storage (execCommand executor workDir command)
  pure output.toJson

/-- The mini agent over an executor and a working directory. -/
def agent (executor : Executor) (workDir : System.FilePath) (config : Config) : Agent := {
  identity := .mkObj [
    ("agent", "mini-swe"), ("step_limit", (config.stepLimit : Lean.Json)),
    ("max_consecutive_format_errors", (config.maxConsecutiveFormatErrors : Lean.Json)),
    ("timeout_seconds", (config.timeoutSeconds : Lean.Json))]
  tools
  view
  next := next config
  act := act executor workDir
}

end Alaya.Agent.MiniSwe
