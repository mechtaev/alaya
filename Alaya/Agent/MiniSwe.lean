import Alaya.Agent
import Alaya.Executor

/-!
A port of mini-SWE-agent's default tool-calling agent (`mini.yaml` + `litellm_model` +
`actions_toolcall`) as an `Alaya.Agent.Agent`: the same prompts, the same `bash` tool, the same
protocol for reading a response and answering a malformed one, and the same limits. Rendering
and command execution are Lean's own — an observation is a JSON value, output is decoded by the
core — and a run ends with a `submit` tool call rather than a sentinel in a command's output.
See `docs/miniswe.md`.
-/

namespace Alaya.Agent.MiniSwe

open Alaya (Result Error Output Executor Uname)
open Alaya.Agent (Agent Event Log Dialogue Outcome Directive)

/-! ## Configuration -/

/-- How mini runs a command: a 30-second limit, and its environment overrides. -/
def defaultExecutor : Executor.Config := {
  timeoutSeconds := 30
  env := #[("PAGER", "cat"), ("MANPAGER", "cat"), ("LESS", "-R"),
           ("PIP_PROGRESS_BAR", "off"), ("TQDM_DISABLE", "1")] }

structure Config where
  task : String
  /-- Maximum model calls; 0 disables the limit (as in mini.yaml). -/
  stepLimit : Nat := 0
  /-- Consecutive format errors tolerated before exiting; 0 disables. -/
  maxConsecutiveFormatErrors : Nat := 3
  /-- How commands are run. -/
  executor : Executor.Config := defaultExecutor
  deriving Inhabited

/-! ## Prompts (rendered `mini.yaml` templates)

These are the exact strings jinja produces from `mini.yaml`, except for the sentences that name
mini's submission sentinel, which name the `submit` tool instead (`submitInstruction`; the test
suite holds mini's original wording). The only variable parts are the task and the `uname`
system-information line. jinja strips one trailing newline, so none of these end in `\n`. -/

def systemMessage : String :=
  "You are a helpful assistant that can interact with a computer."

/-- The instruction for ending a run, as it appears twice in the instance prompt with two
different continuation indents. -/
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

/-! ## The view of an observation -/

/-- How much of a command's output the model is shown; longer outputs show their head and tail. -/
def outputLimit : Nat := 10000

/-- The tool message for an execution result: the recorded `Output` as JSON, with `output` cut to
its first and last `outputLimit / 2` characters when it is `outputLimit` or longer, and the count
of what was left out. The record keeps the whole output; only the model sees the cut. -/
def observation (o : Output) : Lean.Json :=
  let length := o.output.length
  let fields : List (String × Lean.Json) :=
    if length < outputLimit then [("output", o.output)]
    else
      let half := outputLimit / 2
      [("output_head", String.ofList (o.output.toList.take half)),
       ("output_tail", String.ofList (o.output.toList.drop (length - half))),
       ("elided_chars", (length - outputLimit : Nat)),
       ("warning", "Output too long.")]
  let fields := fields ++ [("exit_code", o.exitCode?.map (fun c => Lean.Json.num c.toNat) |>.getD .null)]
  let fields := match o.error? with
    | some error => fields ++ [("error", Lean.Json.str error)]
    | none => fields
  .mkObj fields

/-! ## Action parsing and format errors -/

/-- The last line of the format-error message. -/
def endHint : String :=
  "If you want to end the task, call the `submit` tool\nwithout any other tool call."

/-- The user turn a malformed response is answered with: a truncation notice when the provider
signalled that it cut the response off, otherwise tool-call guidance wrapping `error`. -/
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

/-- One parsed tool call: a shell script to run, or the call that ends the run. -/
inductive Action where
  | bash (id : String) (command : String)
  | submit (id : String) (message : String)
  deriving Inhabited

def Action.id : Action -> String
  | .bash id _ => id
  | .submit id _ => id

/-- A parsed model turn: its actions, or a format-error message to send back as a user turn. -/
inductive Parsed where
  | actions (actions : Array Action)
  | formatError (message : String)

/-- Reads a response's tool calls. Every call must carry arguments that parse as JSON, name a
known tool, and, for `bash`, carry a string `command`; the first call that does not makes the
whole turn a format error, with a message saying what was wrong. -/
def parseActions (response : Chat.Response) : Parsed := Id.run do
  if response.toolCalls.isEmpty then
    return .formatError <| formatErrorMessage
      "No tool calls found in the response. Every response MUST include at least one tool call."
      false response.finishReason?
  let mut actions : Array Action := #[]
  for call in response.toolCalls do
    let problem? : Option String :=
      if let some raw := call.invalidArguments? then
        some ("Error parsing tool call arguments: " ++
          (match Lean.Json.parse raw with | .error e => e | .ok _ => "invalid JSON") ++ ".")
      else match call.name with
        | "submit" => none
        | "bash" =>
          match call.arguments.getObjVal? "command" with
          | .ok (.str _) => none
          | .ok _ => some "The 'command' argument of the bash tool must be a string."
          | .error _ => some "Missing 'command' argument in bash tool call."
        | other => some s!"Unknown tool '{other}'."
    if let some problem := problem? then
      return .formatError (formatErrorMessage problem true response.finishReason?)
    match call.name with
    | "submit" =>
      let message := match call.arguments.getObjVal? "message" with
        | .ok (.str m) => m
        | _ => ""
      actions := actions.push (.submit call.id message)
    | _ =>
      let command := match call.arguments.getObjVal? "command" with
        | .ok (.str c) => c
        | _ => ""
      actions := actions.push (.bash call.id command)
  return .actions actions

/-! ## The agent: view, control, action -/

/-- The projection of the log onto the dialogue, event by event: a message as it is; a
response as the assistant turn it was, unless it failed to parse, in which case the turn is
dropped and the format error is shown as a user turn instead; an observation as the JSON of the
recorded `Output`, with long output cut (`observation`). -/
def view (log : Log) : Dialogue :=
  log.map fun
    | .message m => m
    | .response r =>
      match parseActions r with
      | .actions _ => .assistant r.content? r.toolCalls r.reasoning?
      | .formatError message => .user message
    | .observation id content =>
      let json := match Output.fromJson? content with
        | some output => observation output
        | none => content
      .tool id (.str json.pretty)

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

/-- Runs one `bash` call in the workspace through the executor and records the `Output`. -/
def act (executor : Executor) (workspace : Agent.Workspace) (call : Chat.ToolCall) :
    Result Lean.Json := do
  let command ← match call.name, call.arguments.getObjVal? "command" with
    | "bash", .ok (.str command) => pure command
    | _, _ => throw <| .configuration s!"not a runnable bash call: {call.name}"
  let output ← Result.fromIO Error.storage (executor.bash workspace.dir command)
  pure output.toJson

/-- The mini agent over an executor; the workspace arrives with each act. -/
def agent (executor : Executor) (config : Config) : Agent := {
  identity := .mkObj [
    ("agent", "mini-swe"), ("step_limit", (config.stepLimit : Lean.Json)),
    ("max_consecutive_format_errors", (config.maxConsecutiveFormatErrors : Lean.Json)),
    ("timeout_seconds", (config.executor.timeoutSeconds : Lean.Json))]
  tools
  view
  next := next config
  act := act executor
}

end Alaya.Agent.MiniSwe
