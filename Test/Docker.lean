import Test.Framework
import Alaya

/-! The container executor, against a real docker daemon. Every case skips when the machine has
no usable docker or cannot get the test image, so the suite is safe to run anywhere. -/

namespace DockerTests

open Testing
open Alaya
open Alaya.Agent.MiniSwe

/-- The image the tests run in. Small, and `busybox` gives it a `timeout(1)`. -/
private def imageReference : String := "alpine:3"

private def config : Config := { task := "t", timeoutSeconds := 5 }

/-- Pinned settings for the test image, or `none` when this machine cannot run the suite. -/
private def settings? : TestM (Option Docker.Settings) := do
  let daemonUp ←
    try pure ((← IO.Process.output { cmd := "docker", args := #["info"] }).exitCode == 0)
    catch _ => pure false
  if !daemonUp then return none
  let args := Cli.parse ["--image", imageReference]
  match ← (do (← Docker.settingsFor args imageReference).pin).toBaseIO with
  | .ok settings => pure (some settings)
  | .error _ => pure none

private def skipping (reason : String) : TestM Unit := do
  IO.println s!"SKIP {(← read).name}: {reason}"

/-- Runs `body` with pinned settings, or skips. -/
private def withDocker (body : Docker.Settings -> TestM Unit) : TestM Unit := do
  match ← settings? with
  | some settings => body settings
  | none => skipping s!"no docker daemon, or {imageReference} unavailable"

/-- A model that answers with `responses` in order, for driving one real turn. -/
private def scripted (responses : Array Chat.Response) : TestM Model := do
  let index ← IO.mkRef 0
  pure {
    identity := .mkObj [("model", "scripted")]
    sample := fun _ => pure { next := do
      let i ← Result.fromIO Error.cache <| index.modifyGet fun i => (i, i + 1)
      match responses[i]? with
      | some response => pure response
      | none => throw <| .protocol "scripted model exhausted" } }

private def toolResponse (command : String) : Chat.Response :=
  { toolCalls := #[{ id := "c1", name := "bash"
                     arguments := .mkObj [("command", (command : Lean.Json))] }]
    finishReason? := some "tool_calls", raw := .null }

private def workspace : TestM System.FilePath := do
  let work := (← scratch) / "work"
  assertOk <| Result.fromIO Error.storage (IO.FS.createDirAll work)
  pure work

def suite : Suite := Testing.suite "docker" #[
  test "pins the image to exact bits and reads uname from it, not the host" <| withDocker
    fun settings => do
      check (settings.image != imageReference)
        s!"expected a pinned reference, got {settings.image}"
      check ((settings.image.splitOn "sha256:").length > 1)
        s!"expected a digest, got {settings.image}"
      let uname ← assertOk (Docker.uname settings)
      assertEqual "system" uname.system "Linux"
      check (!uname.machine.isEmpty) "machine should not be empty",

  test "runs commands in the container against the bind-mounted workspace" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings config)
      try
        let wrote ← executor.exec work #["echo hi > a.txt; cat a.txt"] "cat"
        assertEqual "returncode" wrote.returncode 0
        assertEqual "output" wrote.output "hi\n"
        -- The file the container wrote is in the host directory the store snapshots.
        assertEqual "host sees it" (← IO.FS.readFile (work / "a.txt")) "hi\n"
        -- And the host still owns it: a checkout has to be able to wipe this directory.
        IO.FS.removeFile (work / "a.txt")
        let sees ← executor.exec work #["ls /workspace | wc -l"] "ls"
        assertEqual "container sees the removal" sees.output.trimAscii.toString "0"
      finally
        executor.close,

  test "merges stderr into stdout at the fd level, as the local executor does" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings config)
      try
        let merged ← executor.exec work #["echo out; echo err >&2"] "echo"
        assertEqual "merged" merged.output "out\nerr\n"
        let failing ← executor.exec work #["exit 3"] "exit 3"
        assertEqual "exit code passes through" failing.returncode 3
      finally
        executor.close,

  test "environment overrides reach the command, not the docker client" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings config)
      try
        let out ← executor.exec work #["echo $PAGER $TQDM_DISABLE"] "echo"
        assertEqual "mini's overrides" out.output "cat 1\n"
      finally
        executor.close,

  test "a command past the timeout is mini's timeout observation" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings { config with timeoutSeconds := 1 })
      try
        let out ← executor.exec work #["sleep 30"] "sleep 30"
        assertEqual "returncode" out.returncode (-1)
        assertEqual "exception" out.exceptionInfo
          "An error occurred while executing the command: Command 'sleep 30' timed out after 1 seconds"
        -- The run survives it: the next command still works.
        let after ← executor.exec work #["echo alive"] "echo alive"
        assertEqual "still usable" after.output "alive\n"
      finally
        executor.close,

  test "close leaves no container behind" <| withDocker
    fun settings => do
      let work ← workspace
      let executor ← assertOk (Docker.executor settings config)
      let _ ← executor.exec work #["true"] "true"
      let running : IO String := do
        pure (← IO.Process.output {
          cmd := "docker"
          args := #["ps", "--quiet", "--filter", s!"ancestor={settings.image}"] }).stdout
      check (!(← running).trimAscii.isEmpty)
        "expected a running container while the executor is open"
      executor.close
      assertEqual "none left" (← running).trimAscii.toString "",

  test "a step runs its command in the container and snapshots what it wrote" <| withDocker
    fun settings => do
      let work ← workspace
      let project := (← scratch) / "proj"
      assertOk <| Result.fromIO Error.storage (IO.FS.createDirAll project)
      let store ← assertOk <| Cas.Store.create ((← scratch) / "store")
      let model ← scripted #[toolResponse "echo made-in-container > made.txt"]
      let executor ← assertOk (Docker.executor settings config)
      let rt : Runtime := { model, store, workDir := work, executor, config }
      try
        let uname ← assertOk (Docker.uname settings)
        let root ← assertOk <|
          Session.createRoot store config project uname (some settings.image)
        let child ← assertOk <| Session.stepOnce rt "test:model" root
        let state ← assertOk (Session.getState store child)
        assertEqual "image inherited" state.image? (some settings.image)
        -- The container wrote it, the host snapshotted it, the store has it.
        assertEqual "snapshot"
          ((← assertOk (store.readPath state.env "made.txt")).map (String.fromUTF8? ·))
          (some (some "made-in-container\n"))
      finally
        executor.close,

  test "a missing image is a configuration error naming it" <| withDocker
    fun _ => do
      let missing : Docker.Settings := { image := "alaya.invalid/nope@sha256:0" }
      assertError "verifyPresent" missing.verifyPresent fun
        | .configuration m => (m.splitOn "alaya.invalid/nope").length > 1
        | _ => false
]

end DockerTests
