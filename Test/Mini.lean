import Test.Framework
import Test.MiniFixtures
import Alaya

/-! Fidelity tests for the mini-SWE-agent port, and tests of the trajectory tree driven by it.
Golden cases (`Test/MiniFixtures.lean`) are rendered by mini's own jinja templates, so equality
here is byte-level agreement with upstream, except where the port deliberately names its
`submit` tool in place of mini's output sentinel. End-to-end cases drive the real agent over a
Cas-backed workspace with a scripted model. -/

namespace MiniTests

open Testing
open Alaya
open Alaya.Agent (Dialogue Outcome Event Log Stop)
open Alaya.Agent.MiniSwe
open Alaya.Trajectory

private def contains (haystack needle : String) : Bool :=
  (haystack.splitOn needle).length >= 2

/-- Reports the first differing character index, so a golden mismatch is diagnosable. -/
private def assertStringEq (label actual expected : String) : TestM Unit := do
  if actual == expected then return ()
  let a := actual.toList
  let e := expected.toList
  let mut i := 0
  while i < a.length && i < e.length && a[i]? == e[i]? do
    i := i + 1
  fail s!"{label}: differ at char {i}\n  actual  ({actual.length}): {repr (actual.toList.drop (i-min i 10) |>.take 40 |> String.ofList)}\n  expected({expected.length}): {repr (expected.toList.drop (i-min i 10) |>.take 40 |> String.ofList)}"

/-- A fixture rendered by mini's templates, with the sentences that name the submission sentinel
replaced by the port's, which name the `submit` tool. Everything else must match to the byte. -/
private def portOf (miniText : String) : String :=
  let step1 := miniText.replace (miniSubmitInstruction "   ") (submitInstruction "   ")
  let step2 := step1.replace (miniSubmitInstruction "  ") (submitInstruction "  ")
  step2.replace miniEndHint endHint

/-- A fixed `uname`, so prompts do not depend on the machine the tests run on. -/
private def testUname : Uname :=
  { system := "Linux", release := "6.1.0", version := "#1 SMP", machine := "x86_64" }

/-! ## Golden template fidelity -/

def goldenSuite : Suite := suite "mini.golden" #[
  iotest "system message" do
    if systemMessage != "You are a helpful assistant that can interact with a computer." then
      throw <| IO.userError "system message drift",

  test "instance message (Darwin) is mini's, with the submit tool in place of the sentinel" do
    assertStringEq "instance"
      (instanceMessage "Fix the bug in foo.py" "Darwin" "23.5.0" "Darwin Kernel Version 23.5.0" "arm64")
      (portOf MiniFixtures.instanceDarwin)
    -- The replacement is real: the fixture and the prompt differ exactly there.
    check (contains MiniFixtures.instanceDarwin "COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT")
      "the fixture names the sentinel"
    check (!contains (instanceMessage "t" "Linux" "r" "v" "m") "COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT")
      "the prompt does not",

  test "observation rendering matches jinja" do
    for case in MiniFixtures.observations do
      assertStringEq s!"obs/{case.name}"
        (observation { output := case.output, returncode := case.returncode,
                       exceptionInfo := case.exceptionInfo })
        case.expected,

  test "format-error rendering matches jinja, with the submit tool in the closing hint" do
    for case in MiniFixtures.formatErrors do
      assertStringEq s!"fe/{case.name}"
        (formatErrorMessage case.error case.hasToolCalls case.finishReason?)
        (portOf case.expected)
]

/-! ## Parsing and the tool schema -/

private def call (id name command : String) : Chat.ToolCall :=
  { id, name, arguments := .mkObj [("command", (command : Lean.Json))] }

private def submitCall (id : String) (message : String := "") : Chat.ToolCall :=
  { id, name := "submit", arguments := .mkObj [("message", (message : Lean.Json))] }

private def responseWith (calls : Array Chat.ToolCall) (finish := "tool_calls") : Chat.Response :=
  { toolCalls := calls, finishReason? := some finish, raw := .null }

private def actionSummary : Action -> String × String
  | .bash id command => (id, command.compress)
  | .submit id message => (id, "submit:" ++ message)

def parseSuite : Suite := suite "mini.parse" #[
  iotest "bash tool schema is exact" do
    -- mini's BASH_TOOL, compared field-for-field (Json.compress emits keys in sorted order).
    let expected := "{\"function\":{\"description\":\"Execute a bash command\",\"name\":\"bash\",\"parameters\":{\"properties\":{\"command\":{\"description\":\"The bash command to execute\",\"type\":\"string\"}},\"required\":[\"command\"],\"type\":\"object\"}},\"type\":\"function\"}"
    if bashTool.toJson.compress != expected then
      throw <| IO.userError s!"tool schema drift:\n{bashTool.toJson.compress}",

  test "no tool calls is a format error" do
    match parseActions { content? := some "just prose", finishReason? := some "stop", raw := .null } with
    | .formatError msg => check (contains msg "No tool calls found") "expected no-toolcall error"
    | .actions _ => fail "expected a format error",

  test "unknown tool and missing command" do
    match parseActions (responseWith #[call "c1" "python" "x"]) with
    | .formatError msg => check (contains msg "Unknown tool 'python'.") "unknown tool text"
    | .actions _ => fail "expected format error for unknown tool"
    match parseActions (responseWith #[{ id := "c1", name := "bash", arguments := .mkObj [] }]) with
    | .formatError msg => check (contains msg "Missing 'command'") "missing command text"
    | .actions _ => fail "expected format error for missing command",

  test "valid single and multiple calls parse in order" do
    match parseActions (responseWith #[call "a" "bash" "ls", call "b" "bash" "pwd"]) with
    | .actions cs => assertEqual "actions" (cs.map actionSummary) #[("a", "\"ls\""), ("b", "\"pwd\"")]
    | .formatError _ => fail "expected actions",

  test "a submit call parses as a submit action carrying its message" do
    match parseActions (responseWith #[call "a" "bash" "ls", submitCall "s" "all done"]) with
    | .actions cs =>
      assertEqual "actions" (cs.map actionSummary) #[("a", "\"ls\""), ("s", "submit:all done")]
    | .formatError _ => fail "expected actions"
    match parseActions (responseWith #[{ id := "s", name := "submit", arguments := .mkObj [] }]) with
    | .actions cs => assertEqual "bare submit" (cs.map actionSummary) #[("s", "submit:")]
    | .formatError _ => fail "a submit without a message is still a submit",

  test "invalid arguments JSON is a recoverable format error" do
    -- mini: json.loads fails, args read as {}, so the missing-command error joins the parse error.
    let bad : Chat.ToolCall := { id := "c1", name := "bash", arguments := .null,
                                 invalidArguments? := some "{\"command\": \"ls" }
    match parseActions (responseWith #[bad]) with
    | .formatError msg =>
      check (contains msg "Error parsing tool call arguments: ") "parse error text"
      check (contains msg "Missing 'command' argument in bash tool call.") "missing-command joins it"
    | .actions _ => fail "expected a format error"
    -- when the provider reports a length cut-off, the truncation notice renders instead
    match parseActions { toolCalls := #[bad], finishReason? := some "length", raw := .null } with
    | .formatError msg =>
      check (contains msg "output token limit (finish_reason=length)") "truncation notice"
    | .actions _ => fail "expected a format error",

  test "a non-string command parses as an action carrying its JSON value" do
    let numeric : Chat.ToolCall :=
      { id := "c1", name := "bash", arguments := .mkObj [("command", (42 : Lean.Json))] }
    match parseActions (responseWith #[numeric]) with
    | .actions cs => assertEqual "actions" (cs.map actionSummary) #[("c1", "42")]
    | .formatError _ => fail "expected actions"
]

/-! ## End-to-end runs of the agent on the host -/

private def scriptedModel (responses : Array Chat.Response) : IO Model := do
  let index ← IO.mkRef 0
  pure {
    identity := .mkObj [("model", "scripted")]
    sample := fun _ => pure { next := do
      let i ← Result.fromIO Error.cache <| index.modifyGet fun i => (i, i + 1)
      match responses[i]? with
      | some response => pure response
      | none => throw <| .protocol "scripted model exhausted" } }

private def workDir : TestM System.FilePath := do
  let work := (← scratch) / "work"
  assertOk <| Result.fromIO Error.storage (IO.FS.createDirAll work)
  pure work

/-- Runs the mini agent with a scripted model through the reference loop, then snapshots the
workspace. Returns the view of the final log, the snapshot, and the outcome. -/
private def runAgent (config : Config) (responses : Array Chat.Response) :
    TestM (Dialogue × Cas.Hash × Outcome) := do
  let work ← workDir
  let model ← scriptedModel responses
  let mini := agent (Executor.onHost config.executor) work config
  let sample (dialogue : Dialogue) : Result Chat.Response := do
    (← model.sample { messages := dialogue, tools := mini.tools }).next
  let (log, stop) ← assertOk <| Agent.run mini sample (initialLog config testUname)
  let store ← assertOk <| Cas.Store.create ((← scratch) / "store")
  let env ← assertOk <| store.snapshot work
  match stop with
  | .outcome outcome => pure (view log, env, outcome)
  | .question _ q => fail s!"unexpected question: {q}"

def runSuite : Suite := suite "mini.run" #[
  test "a two-step run edits the workspace and submits" do
    let (dialogue, env, outcome) ← runAgent { task := "t" } #[
      responseWith #[call "c1" "bash" "echo hello > a.txt"],
      responseWith #[submitCall "c2" "my patch\n"]]
    assertEqual "outcome" outcome { status := "Submitted", submission := "my patch\n" }
    -- Dialogue: system, instance, assistant#1, tool-obs#1, assistant#2 (no obs for the submit).
    assertEqual "dialogue length" dialogue.size 5
    match dialogue[3]? with
    | some (Chat.Message.tool "c1" content) =>
      assertStringEq "observation content"
        (match content with | .str s => s | j => j.compress)
        (observation { output := "", returncode := 0 })
    | _ => fail "expected a tool observation at index 3"
    -- The live workspace and the snapshot both reflect the edit.
    assertEqual "workspace file" (← IO.FS.readFile ((← scratch) / "work" / "a.txt")) "hello\n"
    let store ← assertOk <| Cas.Store.create ((← scratch) / "store")
    assertEqual "snapshot file"
      ((← assertOk <| store.readPath env "a.txt").map (String.fromUTF8? ·))
      (some (some "hello\n")),

  test "multiple tool calls in one turn run in order and both observe" do
    let (dialogue, _, outcome) ← runAgent { task := "t" } #[
      responseWith #[call "c1" "bash" "mkdir sub", call "c2" "bash" "echo x > sub/f.txt"],
      responseWith #[submitCall "c3"]]
    assertEqual "submitted" outcome.status "Submitted"
    -- system, instance, assistant#1, obs c1, obs c2, assistant#2
    assertEqual "dialogue length" dialogue.size 6
    assertEqual "nested file written" (← IO.FS.readFile ((← scratch) / "work" / "sub" / "f.txt")) "x\n",

  test "a submit ends the turn: calls after it in the same response never run" do
    let (_, env, outcome) ← runAgent { task := "t" } #[
      responseWith #[call "c1" "bash" "echo a > a.txt", submitCall "s" "done",
                     call "c2" "bash" "echo b > b.txt"]]
    assertEqual "submitted" outcome.status "Submitted"
    let store ← assertOk <| Cas.Store.create ((← scratch) / "store")
    check (← assertOk (store.entryAt? env "a.txt")).isSome "the call before submit ran"
    check (← assertOk (store.entryAt? env "b.txt")).isNone "the call after submit did not",

  test "a format error is appended and the offending turn is dropped" do
    let (dialogue, _, outcome) ← runAgent { task := "t" } #[
      { content? := some "I forgot to call a tool", finishReason? := some "stop", raw := .null },
      responseWith #[submitCall "c1"]]
    assertEqual "submitted after recovery" outcome.status "Submitted"
    -- system, instance, user(format error), assistant(submit). The bad assistant turn is not kept.
    assertEqual "dialogue length" dialogue.size 4
    match dialogue[2]? with
    | some (Chat.Message.user msg) => check (contains msg "Tool call error:") "format error text present"
    | _ => fail "expected a user format-error message at index 2",

  test "repeated format errors exit" do
    let bad : Chat.Response := { content? := some "no tool", finishReason? := some "stop", raw := .null }
    let (dialogue, _, outcome) ← runAgent { task := "t", maxConsecutiveFormatErrors := 3 }
      #[bad, bad, bad, bad]
    assertEqual "exit status" outcome.status "RepeatedFormatError"
    -- system, instance, then three user error messages.
    assertEqual "dialogue length" dialogue.size 5,

  test "the step limit stops the run" do
    let loopCmd := responseWith #[call "c" "bash" "echo working"]
    let (_, _, outcome) ← runAgent { task := "t", stepLimit := 2 }
      #[loopCmd, loopCmd, loopCmd, loopCmd]
    assertEqual "exit status" outcome.status "LimitsExceeded",

  test "a command timeout is reported as an exception observation" do
    let (dialogue, _, _) ← runAgent { task := "t", timeoutSeconds := 1 } #[
      responseWith #[call "c1" "bash" "sleep 30"],
      responseWith #[submitCall "c2"]]
    match dialogue[3]? with
    | some (Chat.Message.tool "c1" content) =>
      let s := match content with | .str s => s | j => j.compress
      check (contains s "timed out after 1 seconds") "timeout exception surfaced"
      check (contains s "\"returncode\": -1") "timeout returncode is -1"
    | _ => fail "expected a timeout observation",

  test "truncated tool arguments recover as a format error, like mini" do
    let bad : Chat.Response := {
      toolCalls := #[{ id := "c1", name := "bash", arguments := .null,
                       invalidArguments? := some "{\"command\": \"ls" }],
      finishReason? := some "length", raw := .null }
    let (dialogue, _, outcome) ← runAgent { task := "t" } #[bad, responseWith #[submitCall "c2"]]
    assertEqual "submitted after recovery" outcome.status "Submitted"
    -- system, instance, user(truncation notice), assistant(submit); the bad turn is dropped.
    assertEqual "dialogue length" dialogue.size 4
    match dialogue[2]? with
    | some (Chat.Message.user msg) =>
      check (contains msg "output token limit (finish_reason=length)") "truncation message"
    | _ => fail "expected a format-error user turn at index 2",

  test "the view keeps the record whole and shows the model a truncation" do
    let long := String.ofList (List.replicate 12000 'x')
    let (dialogue, _, _) ← runAgent { task := "t" } #[
      responseWith #[call "c1" "bash" s!"printf '%s' {long}"],
      responseWith #[submitCall "c2"]]
    match dialogue[3]? with
    | some (Chat.Message.tool "c1" (.str shown)) =>
      check (contains shown "\"elided_chars\": 2000") "the model sees the elision"
      check (shown.length < 11000) "the model is shown about 10000 characters"
    | _ => fail "expected the truncated observation"
]

/-! ## Command execution fidelity -/

private def hostExecutor : Executor := Executor.onHost ({ task := "t" } : Config).executor

def execSuite : Suite := suite "mini.exec" #[
  iotest "lossy UTF-8 decoding matches CPython errors='replace'" do
    -- Expectations produced by CPython's bytes.decode('utf-8', errors='replace').
    let cases : Array (List UInt8 × String) := #[
      ([0xff], "�"),
      ([0xff, 0xfe], "��"),
      ([0xe2, 0x82], "�"),
      ([0xe2, 0x82, 0xac, 0x58], "€X"),
      ([0xe2, 0x41], "�A"),
      ([0xf0, 0x80], "��"),
      ([0xed, 0xa0, 0x80], "���"),
      ([0xc0, 0xaf], "��"),
      ([0x61, 0xc2], "a�"),
      ([0xf4, 0x90, 0x80, 0x80], "����"),
      ([0xf0, 0x9f, 0x98, 0x80], "😀")]
    for (bytes, expected) in cases do
      let actual := Executor.lossyDecodeUtf8 ⟨bytes.toArray⟩
      if actual != expected then
        throw <| IO.userError s!"lossy decode {bytes}: got {repr actual}, want {repr expected}",

  test "stderr is merged into stdout at the fd level" do
    let out ← hostExecutor.bash (← workDir) "echo hi >&2"
    assertEqual "merged output" out.output "hi\n"
    assertEqual "returncode" out.returncode 0,

  test "shell errors match mini's invocation byte-for-byte" do
    -- mini execs ["/bin/sh", "-c", command] with stderr on the stdout fd; for commands whose
    -- output is all on one stream, capturing the streams separately and concatenating is exact.
    let work ← workDir
    for command in ["fi", "echo \"unterminated", "nosuchcmd_alaya_test"] do
      let out ← hostExecutor.bash work command
      let reference ← IO.Process.output { cmd := "/bin/sh", args := #["-c", command] }
      assertEqual s!"output of {repr command}" out.output (reference.stdout ++ reference.stderr)
      assertEqual s!"returncode of {repr command}" out.returncode (Int.ofNat reference.exitCode.toNat),

  test "non-UTF-8 command output is replaced, not dropped" do
    let out ← hostExecutor.bash (← workDir) "printf 'a\\377b'"
    assertEqual "replaced output" out.output "a�b"
    assertEqual "returncode" out.returncode 0,

  test "a spawn failure is an exception observation, not an aborted run" do
    let missing := (← scratch) / "missing"
    let out ← hostExecutor.bash missing "echo hi"
    assertEqual "returncode" out.returncode (-1)
    assertEqual "exception" out.exceptionInfo
      s!"An error occurred while executing the command: [Errno 2] No such file or directory: '{missing}'",

  test "non-string commands reproduce Popen's behavior" do
    let work ← workDir
    -- scalars: CPython's TypeError from list(command)
    let intCase ← execCommand hostExecutor work (42 : Lean.Json)
    assertEqual "int returncode" intCase.returncode (-1)
    assertEqual "int exception" intCase.exceptionInfo
      "An error occurred while executing the command: 'int' object is not iterable"
    let noneCase ← execCommand hostExecutor work .null
    assertEqual "null exception" noneCase.exceptionInfo
      "An error occurred while executing the command: 'NoneType' object is not iterable"
    -- a list splices into shell arguments: ["echo", "hi"] runs `echo` with $0=hi
    let listCase ← execCommand hostExecutor work (.arr #[("echo" : Lean.Json), ("hi" : Lean.Json)])
    assertEqual "list output" listCase.output "\n"
    assertEqual "list returncode" listCase.returncode 0
]

/-! ## The trajectory tree, driven by the mini agent -/

/-- A scripted model wrapped in the persistent cache, so draw indexing and replay behave exactly
as the real stack does — the mechanism `resume`/fork rely on — driving the mini agent. -/
private def cachedRuntime (responses : Array Chat.Response) (config : Config := { task := "t" }) :
    TestM Runtime := do
  let model ← scriptedModel responses
  let cached ← assertOk <| Cache.persistent model { directory := (← scratch) / "cache" }
  let store ← assertOk <| Cas.Store.create ((← scratch) / "store")
  let work ← workDir
  let executor := Executor.onHost config.executor
  pure { store, workDir := work, executor, model := cached, agent := agent executor work config }

/-- A root for the test task over `project`. -/
private def mkRoot (rt : Runtime) (project : System.FilePath) (image? : Option String := none)
    (base? : Option String := none) : TestM Cas.Hash :=
  assertOk <| createRoot rt.store (initialLog { task := "t" } testUname) project (some "t") image? base?

/-- A directory standing in for a hidden test set. -/
private def testsDir : TestM System.FilePath := do
  let dir := (← scratch) / "tests-src"
  assertOk <| Result.fromIO Error.storage do
    IO.FS.createDirAll (dir / "tests")
    IO.FS.writeFile (dir / "tests" / "extra.txt") "hidden\n"
  pure dir

/-- A git checkout whose committed `test_x.py` is the one an evaluation must restore. -/
private def gitProject : TestM System.FilePath := do
  let dir := (← scratch) / "git-proj"
  assertOk <| Result.fromIO Error.storage do
    IO.FS.createDirAll dir
    IO.FS.writeFile (dir / "test_x.py") "assert 1 == 1\n"
  let git (args : Array String) : TestM Unit := do
    let out ← IO.Process.output { cmd := "git", args := #["-C", dir.toString] ++ args }
    if out.exitCode != 0 then fail s!"git {args}: {out.stderr}"
  git #["init", "--quiet"]
  git #["config", "user.email", "t@example.com"]
  git #["config", "user.name", "t"]
  git #["add", "."]
  git #["commit", "--quiet", "-m", "base"]
  pure dir

private def headCommit (dir : System.FilePath) : TestM String := do
  let out ← IO.Process.output { cmd := "git", args := #["-C", dir.toString, "rev-parse", "HEAD"] }
  pure out.stdout.trimAscii.toString

private def emptyProject : TestM System.FilePath := do
  let proj := (← scratch) / "proj"
  assertOk <| Result.fromIO Error.storage (IO.FS.createDirAll proj)
  pure proj

/-- An agent that can ask a person: mini's `bash`, plus `ask_user`, which suspends the run.
Mini itself does not offer the tool, so this is what exercises the trajectory's question and
reply path; it shows an agent needs nothing from the trajectory but the four operations. -/
private def askTool : Chat.ToolDefinition := {
  name := "ask_user"
  description := "Ask the person supervising the run"
  parameters := .object #[("message", .string)]
}

private def askingAgent (executor : Executor) (work : System.FilePath) : Agent.Agent := {
  identity := .mkObj [("agent", "asking-test-agent")]
  tools := #[bashTool, askTool]
  view := fun log => log.map fun
    | .message m => m
    | .response r => .assistant r.content? r.toolCalls r.reasoning?
    | .observation id content => .tool id content
  next := fun log =>
    match log.pending[0]? with
    | none => .sample
    | some call =>
      if call.name == "ask_user" then
        .suspend call ((call.arguments.getObjVal? "message" >>= Lean.Json.getStr?).toOption.getD "?")
      else if call.name == "submit" then .done { status := "Submitted" }
      else .act call
  act := act executor work
}

private def askingRuntime (responses : Array Chat.Response) : TestM Runtime := do
  let rt ← cachedRuntime responses
  pure { rt with agent := askingAgent rt.executor rt.workDir }

def trajectorySuite : Suite := suite "trajectory" #[
  test "tell records a notice the model sees, and the run continues from it" do
    let rt ← cachedRuntime #[responseWith #[call "a" "bash" "echo ok"]]
    let root ← mkRoot rt (← emptyProject)
    let told ← assertOk <| tell rt.store root "Please re-run your checks."
    let state ← assertOk (getState rt.store told)
    check (state.kind == .message) "a tell is a message state"
    check (state.env == (← assertOk (getState rt.store root)).env) "a tell keeps the workspace"
    match (view (← assertOk (logOf rt.store told))).back? with
    | some (.user notice) =>
      check (contains notice "Please re-run your checks.") "the notice carries the message verbatim"
      check (contains notice "<intervention>") "the notice is enveloped"
    | _ => fail "expected the notice as the last user turn"
    let next ← assertOk <| stepOnce rt "test:model" told
    check ((← assertOk (getState rt.store next)).kind == .turn) "the run continues after a tell",

  test "commit --tell lists the changed paths in the notice" do
    let rt ← cachedRuntime #[]
    let root ← mkRoot rt (← emptyProject)
    let edited := (← scratch) / "edited"
    assertOk <| Result.fromIO Error.storage do
      IO.FS.createDirAll edited
      IO.FS.writeFile (edited / "fix.txt") "fixed\n"
    let silent ← assertOk <| commit rt.store root edited (some "fix")
    check (← assertOk (getState rt.store silent)).appended.isEmpty "without --tell a commit stays silent"
    let child ← assertOk <| commit rt.store root edited (some "fix") (tell? := some "I added a file.")
    let state ← assertOk (getState rt.store child)
    check (state.kind == .intervention) "still an intervention"
    match state.intervention? with
    | some i => assertEqual "changed paths" i.changed #["+ fix.txt"]
    | none => fail "expected the intervention record"
    match state.appended.back? with
    | some (.message (.user notice)) =>
      check (contains notice "+ fix.txt" && contains notice "I added a file.")
        "the notice lists the added path and the message"
    | _ => fail "expected a notice",

  test "an ask_user call suspends the run, and a reply continues it" do
    let ask : Chat.ToolCall :=
      { id := "q1", name := "ask_user", arguments := .mkObj [("message", "Exact wording or mine?")] }
    let rt ← askingRuntime #[
      responseWith #[call "a" "bash" "echo before > before.txt", ask,
                     call "b" "bash" "echo after > after.txt"],
      responseWith #[submitCall "c"]]
    let root ← mkRoot rt (← emptyProject)
    let stopped ← assertOk <| resume rt "test:model" root (fun _ => pure ())
    let state ← assertOk (getState rt.store stopped)
    check (state.kind == .question) "the run stops at a question"
    assertEqual "question" state.question? (some { callId := "q1", text := "Exact wording or mine?" })
    check (← assertOk (rt.store.entryAt? state.env "before.txt")).isSome
      "the call before the question ran"
    check (← assertOk (rt.store.entryAt? state.env "after.txt")).isNone
      "the call after the question did not run"
    check ((← assertOk (waiting rt.store)).size == 1) "the question is open"
    match ← (stepOnce rt "test:model" stopped).toBaseIO with
    | .ok _ => fail "a waiting state must not be continued without a reply"
    | .error _ => pure ()
    let answered ← assertOk <| reply rt.store stopped "Exact wording."
    check ((← assertOk (getState rt.store answered)).kind == .reply) "a reply state"
    match (← assertOk (logOf rt.store answered)).back? with
    | some (.observation "q1" (.str "Exact wording.")) => pure ()
    | _ => fail "the reply is the observation of the asking call, verbatim"
    check (← assertOk (waiting rt.store)).isEmpty "an answered question is not open"
    let final ← assertOk <| resume rt "test:model" answered (fun _ => pure ())
    check ((← assertOk (getState rt.store final)).outcome?.isSome)
      "the run continues to its outcome after the reply",

  test "the report carries each state's context exactly as the model is sent it" do
    let rt ← cachedRuntime #[
      responseWith #[call "a" "bash" "echo one", call "b" "bash" "echo two"],
      responseWith #[]]   -- a format error: the view substitutes a user turn, and the wire has it
    let root ← mkRoot rt (← emptyProject)
    let first ← assertOk <| stepOnce rt "test:model" root
    let second ← assertOk <| stepOnce rt "test:model" first
    let page ← assertOk <| Html.dataJson rt.store view tools
    let states ← assertOk <| Result.fromExcept Error.storage (page.getObjVal? "states" >>= Lean.Json.getArr?)
    let envelope ← assertOk <| Result.fromExcept Error.storage (page.getObjVal? "request")
    -- Assemble the context as the page does: every state's `wire` from the root down.
    let wireOf (hash : Cas.Hash) : TestM (Array Lean.Json) := do
      match states.find? (fun s => (s.getObjVal? "hash" >>= Lean.Json.getStr?).toOption == some hash.hex) with
      | some s => assertOk <| Result.fromExcept Error.storage (s.getObjVal? "wire" >>= Lean.Json.getArr?)
      | none => fail s!"state {hash.hex} missing from the report"
    let assembled := envelope.setObjVal! "messages"
      (.arr ((← wireOf root) ++ (← wireOf first) ++ (← wireOf second)))
    let sent : Chat.Request := { messages := view (← assertOk (logOf rt.store second)), tools }
    assertStringEq "request" assembled.compress sent.toJson.compress
    check ((← wireOf second).size == 1) "the format-error state adds exactly one wire message",

  iotest "events round-trip through storage" do
    let events : Array Event := #[
      .message (.system "sys"), .message (.user "task text"),
      .response {
        content? := some "thinking", reasoning? := some "trace", finishReason? := some "tool_calls",
        usage? := some { input? := some 10, output? := some 5 }, raw := .null,
        toolCalls := #[
          { id := "c1", name := "bash", arguments := .mkObj [("command", ("ls" : Lean.Json))] },
          { id := "c2", name := "bash", arguments := .null, invalidArguments? := some "{\"command\": \"x" }] },
      .observation "c1" (.mkObj [("output", "a\n"), ("returncode", (0 : Lean.Json))]),
      .observation "c2" (.str "plain text")]
    for event in events do
      match eventFromJson (eventToJson event) with
      | .error e => throw <| IO.userError s!"round-trip failed: {e}"
      | .ok back =>
        if (eventToJson back).compress != (eventToJson event).compress then
          throw <| IO.userError s!"round-trip mismatch: {(eventToJson back).compress}",

  iotest "a version-1 state loads with its messages lifted to events" do
    let v1 := Lean.Json.mkObj [
      ("v", (1 : Lean.Json)), ("parent", .null), ("env", "ab"), ("kind", "agent"),
      ("appended", .arr #[
        .mkObj [("role", "assistant"), ("content", "x"), ("tool_calls", .arr #[])],
        .mkObj [("role", "tool"), ("tool_call_id", "c1"), ("content", "{\"returncode\": 0}")]]),
      ("commands", .arr #[]), ("outcome", .null), ("note", .null)]
    match State.fromJson v1 with
    | .error e => throw <| IO.userError s!"v1 load failed: {e}"
    | .ok state =>
      if state.kind != .turn then throw <| IO.userError "a v1 agent state is a turn"
      match state.appended.toList with
      | [.message (.assistant (some "x") _ _), .message (.tool "c1" _)] => pure ()
      | _ => throw <| IO.userError "v1 messages should be lifted to message events"
      -- The view passes them through, so the old dialogue is what the model still sees.
      if (view state.appended).size != 2 then throw <| IO.userError "lifted messages are shown as is",

  test "the image is recorded at the root and inherited by every child" do
    let rt ← cachedRuntime #[responseWith #[call "c1" "bash" "echo hi"]]
    let pinned := "example.test/img@sha256:0123456789abcdef"
    let root ← mkRoot rt (← emptyProject) (some pinned)
    assertEqual "root" (← assertOk (getState rt.store root)).image? (some pinned)
    let child ← assertOk <| stepOnce rt "test:model" root
    assertEqual "turn" (← assertOk (getState rt.store child)).image? (some pinned)
    let edited ← emptyProject
    let intervention ← assertOk <| commit rt.store child edited (some "by hand")
    assertEqual "intervention" (← assertOk (getState rt.store intervention)).image? (some pinned)
    -- A trajectory created without an image keeps running on the host.
    let hostRoot ← mkRoot rt (← emptyProject)
    assertEqual "host root" (← assertOk (getState rt.store hostRoot)).image? none,

  test "a fork does not inherit the abandoned branch's files" do
    let rt ← cachedRuntime #[
      responseWith #[call "a" "bash" "echo junk > junk.txt"],
      responseWith #[call "b" "bash" "echo other > other.txt"]]
    let root ← mkRoot rt (← emptyProject)
    let first ← assertOk <| stepOnce rt "test:model" root
    check (← assertOk (rt.store.entryAt? (← assertOk (getState rt.store first)).env "junk.txt")).isSome
      "the first branch should have written junk.txt"
    -- Forking checks the root's workspace out again: the first branch's file must be gone.
    let second ← assertOk <| stepOnce rt "test:model" root
    let state ← assertOk (getState rt.store second)
    check (← assertOk (rt.store.entryAt? state.env "other.txt")).isSome
      "the second branch should have written other.txt"
    check (← assertOk (rt.store.entryAt? state.env "junk.txt")).isNone
      "a fork must not start from the abandoned branch's workspace",

  test "an evaluation's overlay never reaches a later turn" do
    let rt ← cachedRuntime #[responseWith #[call "a" "bash" "echo hi > after.txt"]]
    let root ← mkRoot rt (← emptyProject)
    let _ ← assertOk <| evaluate rt root "test -f tests/extra.txt" (.directory (← testsDir))
    -- The hidden tests were overlaid into the work directory; the next turn must not see them.
    let child ← assertOk <| stepOnce rt "test:model" root
    let state ← assertOk (getState rt.store child)
    check (← assertOk (rt.store.entryAt? state.env "tests/extra.txt")).isNone
      "an evaluation's tests must never reach a state the agent continues from",

  test "an evaluation is a leaf that nothing can be built on" do
    let rt ← cachedRuntime #[responseWith #[call "c1" "bash" "echo hi"]]
    let project ← emptyProject
    assertOk <| Result.fromIO Error.storage (IO.FS.writeFile (project / "app.txt") "code\n")
    let root ← mkRoot rt project
    let node ← assertOk <| evaluate rt root "test -f tests/extra.txt" (.directory (← testsDir))
    let state ← assertOk (getState rt.store node)
    assertEqual "kind" state.kind Kind.evaluation
    assertEqual "verdict" (state.evaluation?.map (·.passed)) (some true)
    -- The overlay is in the evaluated tree...
    check (← assertOk (rt.store.entryAt? state.env "tests/extra.txt")).isSome
      "expected the overlay in the evaluated workspace"
    -- ...and not in the state that was evaluated.
    check (← assertOk (rt.store.entryAt? (← assertOk (getState rt.store root)).env
      "tests/extra.txt")).isNone "the agent's state must not gain the tests"
    -- Nothing may continue from it.
    assertError "step" (stepOnce rt "test:model" node) fun
      | .configuration m => (m.splitOn "cannot continue from an evaluation").length > 1
      | _ => false
    assertError "resume" (resume rt "test:model" node (fun _ => pure ())) fun
      | .configuration m => (m.splitOn "cannot continue from an evaluation").length > 1
      | _ => false
    assertError "commit" (commit rt.store node project none) fun
      | .configuration m => (m.splitOn "cannot build on an evaluation").length > 1
      | _ => false,

  test "a failing test command is recorded as a failing verdict, and re-evaluating is a no-op" do
    let rt ← cachedRuntime #[]
    let root ← mkRoot rt (← emptyProject)
    let node ← assertOk <| evaluate rt root "exit 3" .nothing
    let state ← assertOk (getState rt.store node)
    assertEqual "returncode" (state.evaluation?.map (·.returncode)) (some 3)
    assertEqual "passed" (state.evaluation?.map (·.passed)) (some false)
    assertEqual "same node again" (← assertOk <| evaluate rt root "exit 3" .nothing) node
    assertEqual "one child" (← assertOk (children rt.store root)).size 1
    -- A different command is a separate evaluation of the same state.
    let other ← assertOk <| evaluate rt root "true" .nothing
    check (other != node) "expected a distinct node for a distinct command"
    assertEqual "two children" (← assertOk (children rt.store root)).size 2,

  test "a test patch is applied over the agent's edits, from the base commit" do
    let rt ← cachedRuntime #[]
    let project ← gitProject
    let base ← headCommit project
    -- The agent weakens the test and edits the code.
    assertOk <| Result.fromIO Error.storage (IO.FS.writeFile (project / "test_x.py") "assert True\n")
    let root ← mkRoot rt project none (some base)
    let patch := "--- a/test_x.py\n+++ b/test_x.py\n@@ -1 +1 @@\n-assert 1 == 1\n+assert 1 == 2\n"
    let node ← assertOk <| evaluate rt root "cat test_x.py" (.patch patch)
    let state ← assertOk (getState rt.store node)
    -- The agent's version was reset to the base commit, then the patch applied on top.
    assertEqual "hidden test wins" (state.evaluation?.map (·.output)) (some "assert 1 == 2\n")
    assertEqual "patch recorded" (state.evaluation?.bind (·.tests?)).isSome true
    -- The patch file itself is not part of the evaluated tree.
    check (← assertOk (rt.store.entryAt? state.env ".alaya-test.patch")).isNone
      "the patch file must not be snapshotted",

  test "resume drives to submission and records a chain of turns" do
    let rt ← cachedRuntime #[
      responseWith #[call "c1" "bash" "echo hi > a.txt"],
      responseWith #[submitCall "c2" "done"]]
    let root ← mkRoot rt (← emptyProject)
    let final ← assertOk <| resume rt "test:model" root (fun _ => pure ())
    let fstate ← assertOk <| getState rt.store final
    assertEqual "submitted" (fstate.outcome?.map (·.status)) (some "Submitted")
    assertEqual "submission" (fstate.outcome?.map (·.submission)) (some "done")
    -- root → turn(edit) → turn(submit): the submit turn records the response and no observation.
    let middle ← match fstate.parent? with
      | some p => pure p
      | none => fail "the final state has a parent"
    let mstate ← assertOk <| getState rt.store middle
    assertEqual "middle kind" mstate.kind Kind.turn
    assertEqual "middle parent" mstate.parent? (some root)
    assertEqual "middle events" mstate.appended.size 2
    assertEqual "final events" fstate.appended.size 1
    check (← assertOk (rt.store.entryAt? fstate.env "a.txt")).isSome "the edit is in the final workspace"
    -- The tree shows the calls by name and argument.
    let lines ← assertOk <| treeLines rt.store
    check (lines.any fun line => contains line "bash  echo hi > a.txt") "the tree labels a turn by its call"
    check (lines.any fun line => contains line "[Submitted]") "the tree marks the outcome",

  test "replaying a branch from the cache does not ask the model again" do
    let rt ← cachedRuntime #[
      responseWith #[call "c1" "bash" "echo hi > a.txt"],
      responseWith #[submitCall "c2"]]
    let root ← mkRoot rt (← emptyProject)
    let first ← assertOk <| stepOnce rt "test:model" root
    -- A second continuation from the root asks for draw 1: the scripted model's next response.
    let sibling ← assertOk <| stepOnce rt "test:model" root
    check (first != sibling) "a new continuation is a fresh sibling"
    assertEqual "two turn children" (← assertOk (children rt.store root)).size 2
    -- The scripted model is exhausted now, so any further sample would fail; a reply, tell, or
    -- commit child does not consume a draw and does not ask.
    let told ← assertOk <| tell rt.store root "note"
    check ((← assertOk (getState rt.store told)).kind == .message) "a tell is recorded without a sample"
]

def suites : Array Suite := #[goldenSuite, parseSuite, runSuite, execSuite, trajectorySuite]

end MiniTests
