import Test.Framework
import Test.MiniFixtures
import Alaya

/-! Tests of the mini-SWE-agent port, and of the trajectory tree driven by it. The prompt
fixtures (`Test/MiniFixtures.lean`) are rendered by mini's own jinja templates, so the prompts
are checked against upstream to the byte, except where the port names its `submit` tool in place
of mini's output sentinel. End-to-end cases drive the real agent over a Cas-backed workspace with
a scripted model. -/

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

/-- Mini's instruction for ending a run, as it appears twice in its instance prompt with two
different continuation indents; the port names the `submit` tool there instead. -/
private def miniSubmitInstruction (indent : String) : String :=
  "Submit your changes and finish your work by issuing the following command: `echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT`.\n" ++
  indent ++ "Do not combine it with any other command. <important>After this command, you cannot continue working on this task.</important>"

/-- A fixture rendered by mini's templates, with the sentences that name the submission sentinel
replaced by the port's, which name the `submit` tool. Everything else must match to the byte. -/
private def portOf (miniText : String) : String :=
  let step1 := miniText.replace (miniSubmitInstruction "   ") (submitInstruction "   ")
  step1.replace (miniSubmitInstruction "  ") (submitInstruction "  ")

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

  iotest "an observation is the recorded output as JSON, cut when long" do
    let field (json : Lean.Json) (key : String) : Option Lean.Json := (json.getObjVal? key).toOption
    let short := observation { output := "hello\n", exitCode? := some 0 }
    if field short "output" != some "hello\n" || field short "exit_code" != some 0 then
      throw <| IO.userError s!"short observation: {short.compress}"
    if (field short "error").isSome then throw <| IO.userError "no error field when nothing went wrong"
    let failed := observation { output := "partial", error? := some "'sleep 30' timed out after 1 seconds" }
    if field failed "exit_code" != some .null || (field failed "error").isNone then
      throw <| IO.userError s!"failed observation: {failed.compress}"
    -- Unicode passes through as text, not as escapes.
    if field (observation { output := "café ✓ 😀", exitCode? := some 0 }) "output" != some "café ✓ 😀" then
      throw <| IO.userError "unicode should be kept as is"
    -- At the limit the output is replaced by its head and tail and a count of the elision.
    let long := observation { output := String.ofList (List.replicate 12000 'z'), exitCode? := some 0 }
    if (field long "output").isSome then throw <| IO.userError "long output must be cut"
    if field long "elided_chars" != some 2000 then throw <| IO.userError s!"elided: {long.compress}"
    match field long "output_head", field long "output_tail" with
    | some (.str h), some (.str t) =>
      if h.length != 5000 || t.length != 5000 then throw <| IO.userError "head and tail are 5000 each"
    | _, _ => throw <| IO.userError "expected output_head and output_tail"
    -- Just under the limit is shown whole.
    let under := observation { output := String.ofList (List.replicate 9999 'z'), exitCode? := some 0 }
    if (field under "output").isNone then throw <| IO.userError "9999 characters are shown whole",

  iotest "a format error explains the problem, or the cut-off when the provider reports one" do
    let plain := formatErrorMessage "Unknown tool 'python'." true (some "stop")
    if !(contains plain "Unknown tool 'python'." && contains plain endHint) then
      throw <| IO.userError s!"format error text: {plain}"
    let cut := formatErrorMessage "irrelevant" false (some "length")
    if !(contains cut "output token limit (finish_reason=length)") then
      throw <| IO.userError "a length cut-off should be reported as such"
    let cut2 := formatErrorMessage "irrelevant" false (some "tool_calls")
    if !(contains cut2 "finish_reason=tool_calls") then
      throw <| IO.userError "tool_calls with no call is a cut-off"
    let notCut := formatErrorMessage "Unknown tool 'x'." true (some "tool_calls")
    if contains notCut "output token limit" then
      throw <| IO.userError "a response with calls was not cut off"
]

/-! ## Parsing and the tool schema -/

private def call (id name command : String) : Chat.ToolCall :=
  { id, name, arguments := .mkObj [("command", (command : Lean.Json))] }

private def submitCall (id : String) (message : String := "") : Chat.ToolCall :=
  { id, name := "submit", arguments := .mkObj [("message", (message : Lean.Json))] }

private def responseWith (calls : Array Chat.ToolCall) (finish := "tool_calls") : Chat.Response :=
  { toolCalls := calls, finishReason? := some finish }

private def actionSummary : Action -> String × String
  | .bash id command => (id, command)
  | .submit id message => (id, "submit:" ++ message)

def parseSuite : Suite := suite "mini.parse" #[
  iotest "bash tool schema is mini's, in strict mode" do
    -- mini's BASH_TOOL plus the `additionalProperties: false` every strict object carries
    -- (Json.compress emits keys in sorted order).
    let expected := "{\"function\":{\"description\":\"Execute a bash command\",\"name\":\"bash\",\"parameters\":{\"additionalProperties\":false,\"properties\":{\"command\":{\"description\":\"The bash command to execute\",\"type\":\"string\"}},\"required\":[\"command\"],\"type\":\"object\"}},\"type\":\"function\"}"
    if bashTool.toJson.compress != expected then
      throw <| IO.userError s!"tool schema drift:\n{bashTool.toJson.compress}",

  test "no tool calls is a format error" do
    match parseActions { content? := some "just prose", finishReason? := some "stop" } with
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
    | .actions cs => assertEqual "actions" (cs.map actionSummary) #[("a", "ls"), ("b", "pwd")]
    | .formatError _ => fail "expected actions",

  test "a submit call parses as a submit action carrying its message" do
    match parseActions (responseWith #[call "a" "bash" "ls", submitCall "s" "all done"]) with
    | .actions cs =>
      assertEqual "actions" (cs.map actionSummary) #[("a", "ls"), ("s", "submit:all done")]
    | .formatError _ => fail "expected actions"
    match parseActions (responseWith #[{ id := "s", name := "submit", arguments := .mkObj [] }]) with
    | .actions cs => assertEqual "bare submit" (cs.map actionSummary) #[("s", "submit:")]
    | .formatError _ => fail "a submit without a message is still a submit",

  test "invalid arguments JSON is a recoverable format error" do
    let bad : Chat.ToolCall := { id := "c1", name := "bash", arguments := .null,
                                 invalidArguments? := some "{\"command\": \"ls" }
    match parseActions (responseWith #[bad]) with
    | .formatError msg => check (contains msg "Error parsing tool call arguments: ") "parse error text"
    | .actions _ => fail "expected a format error"
    -- when the provider reports a length cut-off, the truncation notice renders instead
    match parseActions { toolCalls := #[bad], finishReason? := some "length" } with
    | .formatError msg =>
      check (contains msg "output token limit (finish_reason=length)") "truncation notice"
    | .actions _ => fail "expected a format error",

  test "a non-string command is a format error" do
    let numeric : Chat.ToolCall :=
      { id := "c1", name := "bash", arguments := .mkObj [("command", (42 : Lean.Json))] }
    match parseActions (responseWith #[numeric]) with
    | .formatError msg => check (contains msg "must be a string") "the message says what is wrong"
    | .actions _ => fail "expected a format error"
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
  let mini := agent (Executor.onHost config.executor) config
  let sample (dialogue : Dialogue) : Result Chat.Response := do
    (← model.sample { messages := dialogue, tools := mini.tools }).next
  let (log, stop) ← assertOk <| Agent.run mini { dir := work } sample (initialLog config testUname)
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
        (observation { output := "", exitCode? := some 0 }).pretty
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
      { content? := some "I forgot to call a tool", finishReason? := some "stop" },
      responseWith #[submitCall "c1"]]
    assertEqual "submitted after recovery" outcome.status "Submitted"
    -- system, instance, user(format error), assistant(submit). The bad assistant turn is not kept.
    assertEqual "dialogue length" dialogue.size 4
    match dialogue[2]? with
    | some (Chat.Message.user msg) => check (contains msg "Tool call error:") "format error text present"
    | _ => fail "expected a user format-error message at index 2",

  test "repeated format errors exit" do
    let bad : Chat.Response := { content? := some "no tool", finishReason? := some "stop" }
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
    let (dialogue, _, _) ← runAgent { task := "t", executor := { defaultExecutor with timeoutSeconds := 1 } } #[
      responseWith #[call "c1" "bash" "sleep 30"],
      responseWith #[submitCall "c2"]]
    match dialogue[3]? with
    | some (Chat.Message.tool "c1" content) =>
      let s := match content with | .str s => s | j => j.compress
      check (contains s "timed out after 1 seconds") "the timeout is reported as the error"
      check (contains s "\"exit_code\": null") "a timed-out command has no exit code"
    | _ => fail "expected a timeout observation",

  test "truncated tool arguments recover as a format error, like mini" do
    let bad : Chat.Response := {
      toolCalls := #[{ id := "c1", name := "bash", arguments := .null,
                       invalidArguments? := some "{\"command\": \"ls" }],
      finishReason? := some "length" }
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
      match Lean.Json.parse shown with
      | .ok json => assertEqual "elided" (json.getObjVal? "elided_chars" >>= Lean.Json.getNat?).toOption (some 2000)
      | .error e => fail s!"the observation should be JSON: {e}"
      check (shown.length < 11000) "the model is shown about 10000 characters"
    | _ => fail "expected the truncated observation"
]

/-! ## Command execution fidelity -/

private def hostExecutor : Executor := Executor.onHost defaultExecutor

def execSuite : Suite := suite "mini.exec" #[
  iotest "invalid UTF-8 bytes are replaced and valid text survives" do
    let cases : Array (List UInt8 × String) := #[
      ([0xff], "�"),
      ([0xe2, 0x82, 0xac, 0x58], "€X"),
      ([0x61, 0xc2], "a�"),
      ([0xe2, 0x82], "��"),
      ([0xf0, 0x9f, 0x98, 0x80], "😀")]
    for (bytes, expected) in cases do
      let actual := Executor.lossyDecodeUtf8 ⟨bytes.toArray⟩
      if actual != expected then
        throw <| IO.userError s!"lossy decode {bytes}: got {repr actual}, want {repr expected}",

  test "stderr is merged into stdout at the fd level" do
    let out ← hostExecutor.bash (← workDir) "echo hi >&2"
    assertEqual "merged output" out.output "hi\n"
    assertEqual "exit code" out.exitCode? (some 0),

  test "shell diagnostics are the shell's own, with stderr merged" do
    -- The inner shell sees the script as `$1`, so its messages are what `/bin/sh -c` prints; for
    -- commands whose output is all on one stream, concatenating the streams is exact.
    let work ← workDir
    for command in ["fi", "echo \"unterminated", "nosuchcmd_alaya_test"] do
      let out ← hostExecutor.bash work command
      let reference ← IO.Process.output { cmd := "/bin/sh", args := #["-c", command] }
      assertEqual s!"output of {repr command}" out.output (reference.stdout ++ reference.stderr)
      assertEqual s!"exit code of {repr command}" out.exitCode? (some reference.exitCode),

  test "non-UTF-8 command output is replaced, not dropped" do
    let out ← hostExecutor.bash (← workDir) "printf 'a\\377b'"
    assertEqual "replaced output" out.output "a�b"
    assertEqual "exit code" out.exitCode? (some 0),

  test "a command that cannot run is an error observation, not an aborted run" do
    let missing := (← scratch) / "missing"
    let out ← hostExecutor.bash missing "echo hi"
    assertEqual "no exit code" out.exitCode? none
    check (((out.error?.getD "").splitOn missing.toString).length > 1) "the error names the directory"
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
  pure { store, workDir := work, executor, model := cached, agent := agent executor config }

/-- A root for the test task over `project`. -/
private def mkRoot (rt : Runtime) (project : System.FilePath) (image? : Option String := none) :
    TestM Cas.Hash :=
  assertOk <| createRoot rt.store (initialLog { task := "t" } testUname) project (some "t") image?

/-- A directory standing in for a hidden test set. -/
private def testsDir : TestM System.FilePath := do
  let dir := (← scratch) / "tests-src"
  assertOk <| Result.fromIO Error.storage do
    IO.FS.createDirAll (dir / "tests")
    IO.FS.writeFile (dir / "tests" / "extra.txt") "hidden\n"
  -- Absolute: a grader runs inside the checkout, where a relative path would not resolve.
  assertOk <| Result.fromIO Error.storage (IO.FS.realPath dir)

private def emptyProject : TestM System.FilePath := do
  let proj := (← scratch) / "proj"
  assertOk <| Result.fromIO Error.storage (IO.FS.createDirAll proj)
  pure proj

/-- An agent that can ask a person: mini's `bash`, plus `ask_user`, which stops the run to wait.
Mini itself does not offer the tool, so this is what exercises the trajectory's question and
reply path; it shows an agent needs nothing from the trajectory but the four operations. -/
private def askTool : Chat.ToolDefinition := {
  name := "ask_user"
  description := "Ask the person supervising the run"
  parameters := .object #[("message", .string)]
}

private def askingAgent (executor : Executor) : Agent.Agent := {
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
        .ask call.id ((call.arguments.getObjVal? "message" >>= Lean.Json.getStr?).toOption.getD "?")
      else if call.name == "submit" then .done { status := "Submitted" }
      else .act call
  act := act executor
}

private def askingRuntime (responses : Array Chat.Response) : TestM Runtime := do
  let rt ← cachedRuntime responses
  pure { rt with agent := askingAgent rt.executor }

def trajectorySuite : Suite := suite "trajectory" #[
  test "tell records a notice the model sees, and the run continues from it" do
    let rt ← cachedRuntime #[responseWith #[call "a" "bash" "echo ok"]]
    let root ← mkRoot rt (← emptyProject)
    let told ← assertOk <| tell rt.store root "Please re-run your checks."
    let state ← assertOk (getState rt.store told)
    check (state.kind == .message) "a tell is a message state"
    check (state.workspace == (← assertOk (getState rt.store root)).workspace) "a tell keeps the workspace"
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

  test "an ask_user call stops the run at a question, and a reply continues it" do
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
    check (← assertOk (rt.store.entryAt? state.workspace "before.txt")).isSome
      "the call before the question ran"
    check (← assertOk (rt.store.entryAt? state.workspace "after.txt")).isNone
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
        usage? := some { input? := some 10, output? := some 5 },
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
    check (← assertOk (rt.store.entryAt? (← assertOk (getState rt.store first)).workspace "junk.txt")).isSome
      "the first branch should have written junk.txt"
    -- Forking checks the root's workspace out again: the first branch's file must be gone.
    let second ← assertOk <| stepOnce rt "test:model" root
    let state ← assertOk (getState rt.store second)
    check (← assertOk (rt.store.entryAt? state.workspace "other.txt")).isSome
      "the second branch should have written other.txt"
    check (← assertOk (rt.store.entryAt? state.workspace "junk.txt")).isNone
      "a fork must not start from the abandoned branch's workspace",

  test "a grader runs on the host against a checkout, and its files never reach a later turn" do
    let rt ← cachedRuntime #[responseWith #[call "a" "bash" "echo hi > after.txt"]]
    let root ← mkRoot rt (← emptyProject)
    let tests ← testsDir
    let scratch := (← scratch) / "eval"
    let node ← assertOk <| evaluate rt.store scratch root
      ("cp -R " ++ tests.toString ++ "/. {checkout}/ && test -f tests/extra.txt")
    let state ← assertOk (getState rt.store node)
    assertEqual "kind" state.kind Kind.evaluation
    assertEqual "verdict" (state.evaluation?.map (·.passed)) (some true)
    -- The grader's copy went into the checkout, not into any state: the evaluation's workspace
    -- is its parent's, and the next turn from the root does not see the tests either.
    assertEqual "workspace is the parent's" state.workspace (← assertOk (getState rt.store root)).workspace
    let child ← assertOk <| stepOnce rt "test:model" root
    check (← assertOk (rt.store.entryAt? (← assertOk (getState rt.store child)).workspace "tests/extra.txt")).isNone
      "a grader's files must never reach a state the agent continues from"
    -- Nothing may continue from the evaluation.
    assertError "step" (stepOnce rt "test:model" node) fun
      | .configuration m => (m.splitOn "cannot continue from an evaluation").length > 1
      | _ => false
    assertError "commit" (commit rt.store node (← emptyProject) none) fun
      | .configuration m => (m.splitOn "cannot build on an evaluation").length > 1
      | _ => false,

  test "a failing grader is a failing verdict, and re-evaluating is a no-op" do
    let rt ← cachedRuntime #[]
    let root ← mkRoot rt (← emptyProject)
    let scratch := (← scratch) / "eval"
    let node ← assertOk <| evaluate rt.store scratch root "exit 3"
    let state ← assertOk (getState rt.store node)
    assertEqual "returncode" (state.evaluation?.map (·.returncode)) (some 3)
    assertEqual "passed" (state.evaluation?.map (·.passed)) (some false)
    assertEqual "no evidence" (state.evaluation?.bind (·.evidence?)) none
    assertEqual "same node again" (← assertOk <| evaluate rt.store scratch root "exit 3") node
    assertEqual "one child" (← assertOk (children rt.store root)).size 1
    -- A different grader is a separate evaluation of the same state.
    let other ← assertOk <| evaluate rt.store scratch root "true"
    check (other != node) "expected a distinct node for a distinct grader"
    assertEqual "two children" (← assertOk (children rt.store root)).size 2,

  test "a grader's verdict.json decides, and its output directory is kept as evidence" do
    let rt ← cachedRuntime #[]
    let project ← emptyProject
    assertOk <| Result.fromIO Error.storage (IO.FS.writeFile (project / "app.txt") "code\n")
    let root ← mkRoot rt project
    let scratch := (← scratch) / "eval"
    -- Exit status 1, but the verdict says passed: the verdict wins. The report beside it is kept.
    let grader := "test -f {checkout}/app.txt && " ++
      "printf '{\"passed\": true, \"score\": 3}' > {out}/verdict.json && echo detail > {out}/report.txt && exit 1"
    let node ← assertOk <| evaluate rt.store scratch root grader
    let state ← assertOk (getState rt.store node)
    let some e := state.evaluation? | fail "expected an evaluation"
    assertEqual "returncode" e.returncode 1
    check e.passed "verdict.json says passed"
    assertEqual "score" (e.summary?.bind fun s => (s.getObjVal? "score" >>= Lean.Json.getNat?).toOption) (some 3)
    let some evidence := e.evidence? | fail "expected the output directory as evidence"
    assertEqual "report kept"
      ((← assertOk (rt.store.readPath evidence "report.txt")).map (String.fromUTF8? ·))
      (some (some "detail\n"))
    check (← assertOk (rt.store.entryAt? evidence "verdict.json")).isSome "verdict.json is in the evidence"
    -- The checkout is gone afterwards; only the store holds what was tested.
    check (!(← (scratch / "checkout").pathExists)) "the checkout is discarded",

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
    check (← assertOk (rt.store.entryAt? fstate.workspace "a.txt")).isSome "the edit is in the final workspace"
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
