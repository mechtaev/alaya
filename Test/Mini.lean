import Test.Framework
import Test.MiniFixtures
import Alaya

/-! Fidelity tests for the mini-SWE-agent port. Golden cases (`Test/MiniFixtures.lean`) are
rendered by mini's own jinja templates, so equality here is byte-level agreement with upstream.
End-to-end cases drive the real loop over a Cas-backed workspace with a scripted model. -/

namespace MiniTests

open Testing
open Alaya
open Alaya.Agent (Dialogue Outcome)
open Alaya.Agent.MiniSwe

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

/-! ## Golden template fidelity -/

def goldenSuite : Suite := suite "mini.golden" #[
  iotest "system message" do
    if systemMessage != "You are a helpful assistant that can interact with a computer." then
      throw <| IO.userError "system message drift",

  test "instance message (Darwin)" do
    assertStringEq "instance"
      (instanceMessage "Fix the bug in foo.py" "Darwin" "23.5.0" "Darwin Kernel Version 23.5.0" "arm64")
      MiniFixtures.instanceDarwin,

  test "observation rendering matches jinja" do
    for case in MiniFixtures.observations do
      assertStringEq s!"obs/{case.name}"
        (observation { output := case.output, returncode := case.returncode,
                       exceptionInfo := case.exceptionInfo })
        case.expected,

  test "format-error rendering matches jinja" do
    for case in MiniFixtures.formatErrors do
      assertStringEq s!"fe/{case.name}"
        (formatErrorMessage case.error case.hasToolCalls case.finishReason?)
        case.expected
]

/-! ## Parsing, submission, tool schema -/

private def call (id name command : String) : Chat.ToolCall :=
  { id, name, arguments := .mkObj [("command", (command : Lean.Json))] }

private def responseWith (calls : Array Chat.ToolCall) (finish := "tool_calls") : Chat.Response :=
  { toolCalls := calls, finishReason? := some finish, raw := .null }

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
    | .actions cs =>
      assertEqual "actions" (cs.map fun (id, c) => (id, c.compress)) #[("a", "\"ls\""), ("b", "\"pwd\"")]
    | .formatError _ => fail "expected actions",

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
    | .actions cs => assertEqual "actions" (cs.map fun (id, c) => (id, c.compress)) #[("c1", "42")]
    | .formatError _ => fail "expected actions",

  iotest "submission detection" do
    let magic := "COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT"
    if submission? magic 0 != some "" then throw <| IO.userError "bare magic should submit empty"
    if submission? s!"  \n{magic}\nmy patch\n" 0 != some "my patch\n" then
      throw <| IO.userError "submission body should follow the first line"
    if submission? magic 1 != none then throw <| IO.userError "nonzero returncode must not submit"
    if submission? s!"prefix {magic}" 0 != none then throw <| IO.userError "magic must be the first line"
    -- Python `str.splitlines` boundaries and `str.strip` whitespace, beyond plain "\n"
    if submission? s!"{magic}\r\nwin" 0 != some "win" then
      throw <| IO.userError "\\r\\n should end the first line as one unit"
    if submission? s!"\u00A0 {magic}\x0Bafter" 0 != some "after" then
      throw <| IO.userError "NBSP should lstrip and \\v should be a line boundary"
    if submission? s!"{magic}\rcr" 0 != some "cr" then
      throw <| IO.userError "\\r alone should be a line boundary"
]

/-! ## End-to-end runs over a Cas workspace -/

private def scriptedModel (responses : Array Chat.Response) : IO Model := do
  let index ← IO.mkRef 0
  pure {
    identity := .mkObj [("model", "scripted")]
    sample := fun _ => pure { next := do
      let i ← Result.fromIO Error.cache <| index.modifyGet fun i => (i, i + 1)
      match responses[i]? with
      | some response => pure response
      | none => throw <| .protocol "scripted model exhausted" } }

private def runAgent (config : Config) (responses : Array Chat.Response) :
    TestM (Dialogue × Cas.Hash × Outcome) := do
  let model ← scriptedModel responses
  let rt ← assertOk <| Runtime.create model config ((← scratch) / "work") ((← scratch) / "store")
  assertOk (run rt)

def runSuite : Suite := suite "mini.run" #[
  test "a two-step run edits the workspace and submits" do
    let (dialogue, env, outcome) ← runAgent { task := "t" } #[
      responseWith #[call "c1" "bash" "echo hello > a.txt"],
      responseWith #[call "c2" "bash" "printf 'COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT\\nmy patch\\n'"]]
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
      responseWith #[call "c3" "bash" "echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT"]]
    assertEqual "submitted" outcome.status "Submitted"
    -- system, instance, assistant#1, obs c1, obs c2, assistant#2
    assertEqual "dialogue length" dialogue.size 6
    assertEqual "nested file written" (← IO.FS.readFile ((← scratch) / "work" / "sub" / "f.txt")) "x\n",

  test "a format error is appended and the offending turn is dropped" do
    let (dialogue, _, outcome) ← runAgent { task := "t" } #[
      { content? := some "I forgot to call a tool", finishReason? := some "stop", raw := .null },
      responseWith #[call "c1" "bash" "echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT"]]
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
      responseWith #[call "c2" "bash" "echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT"]]
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
    let (dialogue, _, outcome) ← runAgent { task := "t" } #[
      bad,
      responseWith #[call "c2" "bash" "echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT"]]
    assertEqual "submitted after recovery" outcome.status "Submitted"
    -- system, instance, user(truncation notice), assistant(submit); the bad turn is dropped.
    assertEqual "dialogue length" dialogue.size 4
    match dialogue[2]? with
    | some (Chat.Message.user msg) =>
      check (contains msg "output token limit (finish_reason=length)") "truncation message"
    | _ => fail "expected a format-error user turn at index 2"
]

/-! ## Command execution fidelity -/

private def mkRuntime : TestM Runtime := do
  let model ← scriptedModel #[]
  assertOk <| Runtime.create model { task := "t" } ((← scratch) / "work") ((← scratch) / "store")

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
      let actual := lossyDecodeUtf8 ⟨bytes.toArray⟩
      if actual != expected then
        throw <| IO.userError s!"lossy decode {bytes}: got {repr actual}, want {repr expected}",

  test "stderr is merged into stdout at the fd level" do
    let out ← execBash (← mkRuntime) "echo hi >&2"
    assertEqual "merged output" out.output "hi\n"
    assertEqual "returncode" out.returncode 0,

  test "shell errors match mini's invocation byte-for-byte" do
    -- mini execs ["/bin/sh", "-c", command] with stderr on the stdout fd; for commands whose
    -- output is all on one stream, capturing the streams separately and concatenating is exact.
    let rt ← mkRuntime
    for command in ["fi", "echo \"unterminated", "nosuchcmd_alaya_test"] do
      let out ← execBash rt command
      let reference ← IO.Process.output { cmd := "/bin/sh", args := #["-c", command] }
      assertEqual s!"output of {repr command}" out.output (reference.stdout ++ reference.stderr)
      assertEqual s!"returncode of {repr command}" out.returncode (Int.ofNat reference.exitCode.toNat),

  test "non-UTF-8 command output is replaced, not dropped" do
    let out ← execBash (← mkRuntime) "printf 'a\\377b'"
    assertEqual "replaced output" out.output "a�b"
    assertEqual "returncode" out.returncode 0,

  test "a spawn failure is an exception observation, not an aborted run" do
    let rt ← mkRuntime
    let missing := (← scratch) / "missing"
    let out ← execBash { rt with workDir := missing } "echo hi"
    assertEqual "returncode" out.returncode (-1)
    assertEqual "exception" out.exceptionInfo
      s!"An error occurred while executing the command: [Errno 2] No such file or directory: '{missing}'",

  test "non-string commands reproduce Popen's behavior" do
    let rt ← mkRuntime
    -- scalars: CPython's TypeError from list(command)
    let intCase ← execCommand rt (42 : Lean.Json)
    assertEqual "int returncode" intCase.returncode (-1)
    assertEqual "int exception" intCase.exceptionInfo
      "An error occurred while executing the command: 'int' object is not iterable"
    let noneCase ← execCommand rt .null
    assertEqual "null exception" noneCase.exceptionInfo
      "An error occurred while executing the command: 'NoneType' object is not iterable"
    -- a list splices into shell arguments: ["echo", "hi"] runs `echo` with $0=hi
    let listCase ← execCommand rt (.arr #[("echo" : Lean.Json), ("hi" : Lean.Json)])
    assertEqual "list output" listCase.output "\n"
    assertEqual "list returncode" listCase.returncode 0
]

/-! ## Trajectory tree (Session) -/

open Alaya.Agent.MiniSwe.Session

/-- A scripted model wrapped in the persistent cache, so draw indexing and replay behave exactly
as the real stack does — the mechanism `resume`/fork rely on. -/
private def cachedRuntime (responses : Array Chat.Response) : TestM Runtime := do
  let model ← scriptedModel responses
  let cached ← assertOk <| Cache.persistent model { directory := (← scratch) / "cache" }
  let store ← assertOk <| Cas.Store.create ((← scratch) / "store")
  let work := (← scratch) / "work"
  assertOk <| Result.fromIO Error.storage (IO.FS.createDirAll work)
  let config : Config := { task := "t" }
  pure { model := cached, store, workDir := work, config, executor := Executor.local config }

/-- A fixed `uname`, so root states do not depend on the machine the tests run on. -/
private def testUname : Uname :=
  { system := "Linux", release := "6.1.0", version := "#1 SMP", machine := "x86_64" }

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

def sessionSuite : Suite := suite "mini.session" #[
  iotest "messages round-trip through storage" do
    let messages : Array Chat.Message := #[
      .system "sys", .user "task text",
      .assistant (some "reasoning") #[
        { id := "c1", name := "bash", arguments := .mkObj [("command", ("ls" : Lean.Json))] },
        { id := "c2", name := "bash", arguments := .null, invalidArguments? := some "{\"command\": \"x" }],
      .tool "c1" (.str "observation"),
      .tool "c2" (.mkObj [("returncode", (0 : Lean.Json))])]
    for message in messages do
      match messageFromJson (messageToJson message) with
      | .error e => throw <| IO.userError s!"round-trip failed: {e}"
      | .ok back =>
        if (messageToJson back).compress != (messageToJson message).compress then
          throw <| IO.userError s!"round-trip mismatch: {(messageToJson back).compress}",

  test "the image is recorded at the root and inherited by every child" do
    let rt ← cachedRuntime #[responseWith #[call "c1" "bash" "echo hi"]]
    let pinned := "example.test/img@sha256:0123456789abcdef"
    let root ← assertOk <|
      createRoot rt.store { task := "t" } (← emptyProject) testUname (some pinned)
    assertEqual "root" (← assertOk (getState rt.store root)).image? (some pinned)
    let child ← assertOk <| stepOnce rt "test:model" root
    assertEqual "agent turn" (← assertOk (getState rt.store child)).image? (some pinned)
    let edited ← emptyProject
    let intervention ← assertOk <| commit rt.store child edited (some "by hand")
    assertEqual "intervention" (← assertOk (getState rt.store intervention)).image? (some pinned)
    -- A trajectory created without an image keeps running on the host.
    let hostRoot ← assertOk <| createRoot rt.store { task := "t" } (← emptyProject) testUname
    assertEqual "host root" (← assertOk (getState rt.store hostRoot)).image? none,

  test "an evaluation is a leaf that nothing can be built on" do
    let rt ← cachedRuntime #[responseWith #[call "c1" "bash" "echo hi"]]
    let project ← emptyProject
    assertOk <| Result.fromIO Error.storage (IO.FS.writeFile (project / "app.txt") "code\n")
    let root ← assertOk <| createRoot rt.store { task := "t" } project testUname
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
    let root ← assertOk <| createRoot rt.store { task := "t" } (← emptyProject) testUname
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
    let root ← assertOk <|
      createRoot rt.store { task := "t" } project testUname none (some base)
    let patch := "--- a/test_x.py\n+++ b/test_x.py\n@@ -1 +1 @@\n-assert 1 == 1\n+assert 1 == 2\n"
    let node ← assertOk <| evaluate rt root "cat test_x.py" (.patch patch)
    let state ← assertOk (getState rt.store node)
    -- The agent's version was reset to the base commit, then the patch applied on top.
    assertEqual "hidden test wins" (state.evaluation?.map (·.output)) (some "assert 1 == 2\n")
    assertEqual "patch recorded" (state.evaluation?.bind (·.tests?)).isSome true
    -- The patch file itself is not part of the evaluated tree.
    check (← assertOk (rt.store.entryAt? state.env ".alaya-test.patch")).isNone
      "the patch file must not be snapshotted",

  test "resume drives to submission and records a chain" do
    let rt ← cachedRuntime #[
      responseWith #[call "c1" "bash" "echo hi > a.txt"],
      responseWith #[call "c2" "bash" "echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT"]]
    let root ← assertOk <| createRoot rt.store { task := "t" } (← emptyProject) testUname
    let final ← assertOk <| resume rt "test:model" root (fun _ => pure ())
    let fstate ← assertOk <| getState rt.store final
    assertEqual "submitted" (fstate.outcome?.map (·.status)) (some "Submitted")
    -- root → agent(edit) → agent(submit)
    assertEqual "state count" (← assertOk (allStates rt.store)).size 3
    -- system, instance, assistant#1, obs#1, assistant#2 (no obs for the submit)
    assertEqual "dialogue length" (← assertOk (dialogueOf rt.store final)).size 5
    -- the workspace edit is captured in the recorded snapshot
    let mid ← assertOk (getState rt.store fstate.parent?.get!)
    assertEqual "edit snapshot"
      ((← assertOk (rt.store.readPath mid.env "a.txt")).map (String.fromUTF8? ·))
      (some (some "hi\n")),

  test "resuming a node twice forks into distinct siblings, replaying the first draw" do
    let rt ← cachedRuntime #[
      responseWith #[call "a" "bash" "echo one"],
      responseWith #[call "b" "bash" "echo two"]]
    let root ← assertOk <| createRoot rt.store { task := "t" } (← emptyProject) testUname
    let dialogue ← assertOk (dialogueOf rt.store root)
    let env := (← assertOk (getState rt.store root)).env
    let (c1, _, _, _, _) ← assertOk <| advance rt "m" root dialogue env 0
    let (c2, _, _, _, _) ← assertOk <| advance rt "m" root dialogue env 0
    check (c1 != c2) "forks are distinct states"
    assertEqual "two siblings" (← assertOk (children rt.store root)).size 2
    -- first advance drew index 0 ("one"); the second replayed 0 from cache and drew index 1 ("two")
    let cmd (h : Cas.Hash) : TestM String := do
      pure ((← assertOk (getState rt.store h)).commands[0]!.command.compress)
    assertEqual "first draw" (← cmd c1) "\"echo one\""
    assertEqual "second draw" (← cmd c2) "\"echo two\"",

  test "commit records an intervention child sharing the parent dialogue" do
    let rt ← cachedRuntime #[]
    let root ← assertOk <| createRoot rt.store { task := "t" } (← emptyProject) testUname
    let edit := (← scratch) / "edit"
    assertOk <| Result.fromIO Error.storage (IO.FS.createDirAll edit)
    assertOk <| Result.fromIO Error.storage (IO.FS.writeFile (edit / "planted.txt") "x")
    let child ← assertOk <| commit rt.store root edit (some "planted a file")
    let cstate ← assertOk (getState rt.store child)
    assertEqual "intervention kind" cstate.kind Kind.intervention
    assertEqual "parent" cstate.parent? (some root)
    check cstate.appended.isEmpty "intervention appends no messages"
    -- the model never saw the edit: dialogues are identical
    assertEqual "shared dialogue"
      (← assertOk (dialogueOf rt.store child)).size (← assertOk (dialogueOf rt.store root)).size,

  test "rm deletes a subtree and leaves the rest" do
    let rt ← cachedRuntime #[
      responseWith #[call "a" "bash" "echo one"],
      responseWith #[call "b" "bash" "echo two"]]
    let root ← assertOk <| createRoot rt.store { task := "t" } (← emptyProject) testUname
    let d0 ← assertOk (dialogueOf rt.store root)
    let e0 := (← assertOk (getState rt.store root)).env
    let (c1, d1, e1, _, _) ← assertOk <| advance rt "m" root d0 e0 0
    let (c2, _, _, _, _) ← assertOk <| advance rt "m" c1 d1 e1 0
    assertEqual "three states before rm" (← assertOk (allStates rt.store)).size 3
    let removed ← assertOk <| removeSubtree rt.store c1
    assertEqual "removed two" removed 2
    assertEqual "root survives" (← assertOk (allStates rt.store)) #[root]
    -- and c2's blob has been reclaimed
    assertError "c2 gone" (getState rt.store c2) (fun _ => true),

  test "resolve accepts an unambiguous hash prefix" do
    let rt ← cachedRuntime #[]
    let root ← assertOk <| createRoot rt.store { task := "t" } (← emptyProject) testUname
    assertEqual "prefix resolves" (← assertOk (resolve rt.store (String.ofList (root.hex.toList.take 10)))) root
]

def suites : Array Suite := #[goldenSuite, parseSuite, runSuite, execSuite, sessionSuite]

end MiniTests
