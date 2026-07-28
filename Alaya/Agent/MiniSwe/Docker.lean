import Alaya.Agent.MiniSwe
import Alaya.Cli

/-!
An `Executor` that runs the agent's commands in a container.

The workspace stays where it was: the runtime's working directory is bind-mounted at
`/workspace`, so the content-addressed store still snapshots a host directory and the trajectory
tree is unaffected by the choice of executor. One container is started per run and every command
goes through `docker exec`, which reproduces mini's persistence *within* a run — an install in
one command is visible to the next.

The deviation that buys: mutations outside `/workspace` are not part of any snapshot, so a
branch resumed in a later run starts from the image again. Anything that must survive branching
has to land in the workspace or in the image.

The command itself sees exactly what it sees locally: the same `exec /bin/sh -c "$@" 2>&1`
trampoline, the same argv, the same merged stderr, and mini's environment overrides applied to
the command rather than to the client.
-/

namespace Alaya.Agent.MiniSwe.Docker

open Alaya (Result Error)

/-- Where the working directory is mounted inside the container. -/
def workMount : String := "/workspace"

/-- How the container is created. `image` is a runnable reference; once `pin`ned it is one that
names exact bits, which is what a trajectory records. -/
structure Settings where
  image : String
  /-- `uid:gid` to run as. Files the agent creates land in the bind-mounted workspace, so on
  Linux this must be the host user or the host can neither snapshot nor wipe them. Docker
  Desktop virtualizes ownership, so macOS leaves it unset. -/
  user? : Option String := none
  /-- `--network`; `none` keeps docker's default. -/
  network? : Option String := none
  /-- Extra `docker run` arguments, verbatim. -/
  extraRunArgs : Array String := #[]
  deriving Repr, Inhabited

/-! ## Talking to the docker client -/

private structure Client where
  exitCode : UInt32
  stdout : String
  stderr : String

private def client (args : Array String) : IO Client := do
  let out ← IO.Process.output { cmd := "docker", args }
  pure { exitCode := out.exitCode
         stdout := out.stdout.trimAscii.toString, stderr := out.stderr.trimAscii.toString }

/-- Runs a docker command, failing with its stderr. Every failure here is a setup problem —
docker missing, daemon down, image absent — so they are configuration errors. -/
private def docker (args : Array String) (what : String) : Result String := do
  let result ← Result.fromIO (fun e => .configuration s!"cannot run docker: {e}") (client args)
  if result.exitCode == 0 then pure result.stdout
  else throw <| .configuration <|
    s!"{what} failed" ++ (if result.stderr.isEmpty then "" else s!": {result.stderr}")

private def inspect? (reference format : String) : IO (Option String) := do
  let result ← client #["image", "inspect", "--format", format, reference]
  pure (if result.exitCode == 0 && !result.stdout.isEmpty then some result.stdout else none)

/-! ## Pinning the image -/

/-- Replaces the image reference with one that names exact bits: its repo digest, or its image
id when it was built locally and has none. Both are runnable, so a trajectory can record one and
a later `resume` can start from it without consulting a tag that may have moved. Pulls once if
the image is not present locally. -/
def Settings.pin (settings : Settings) : Result Settings := do
  let reference := settings.image
  let resolve : Result (Option String) := Result.fromIO Error.configuration do
    match ← inspect? reference "{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}" with
    | some digest => pure (some digest)
    | none => inspect? reference "{{.Id}}"
  match ← resolve with
  | some pinned => pure { settings with image := pinned }
  | none =>
    let _ ← docker #["pull", reference] s!"docker pull {reference}"
    match ← resolve with
    | some pinned => pure { settings with image := pinned }
    | none => throw <| .configuration s!"image {reference} is not available after pulling it"

/-- Checks that a recorded image is still available locally, so a resumed trajectory fails with
a clear message rather than a container that cannot start. -/
def Settings.verifyPresent (settings : Settings) : Result Unit := do
  match ← Result.fromIO Error.configuration (inspect? settings.image "{{.Id}}") with
  | some _ => pure ()
  | none => throw <| .configuration <|
      s!"image {settings.image} is recorded in this trajectory but is not available locally; " ++
      "pull it, or pass --image to run a different one (which will be refused if it differs)"

/-- The host user, as Linux containers must run as it to leave a workspace the host still owns.
Docker Desktop maps ownership itself, so macOS keeps the image's own user. -/
def defaultUser? : IO (Option String) := do
  if System.Platform.isOSX then pure none
  else
    let uid ← IO.Process.output { cmd := "id", args := #["-u"] }
    let gid ← IO.Process.output { cmd := "id", args := #["-g"] }
    if uid.exitCode != 0 || gid.exitCode != 0 then pure none
    else pure (some s!"{uid.stdout.trimAscii}:{gid.stdout.trimAscii}")

/-! ## The container -/

private def runArgs (settings : Settings) : Array String :=
  (match settings.user? with | some user => #["--user", user] | none => #[])
    ++ (match settings.network? with | some network => #["--network", network] | none => #[])
    -- The uid usually has no passwd entry, and tools that want $HOME would write to /.
    ++ #["--env", "HOME=/tmp"]

/-- `uname` inside the image, for the instance prompt. Read with a throwaway container, since it
is needed at `root` time, before any run has started. -/
def uname (settings : Settings) : Result Uname := do
  let script := "uname -s; uname -r; uname -v; uname -m"
  let out ← docker (#["run", "--rm", "--entrypoint", "/bin/sh"] ++ runArgs settings ++
    #[settings.image, "-c", script]) s!"reading uname from {settings.image}"
  match out.splitOn "\n" with
  | [system, release, version, machine] =>
    pure { system := system.trimAscii.toString, release := release.trimAscii.toString
           version := version.trimAscii.toString, machine := machine.trimAscii.toString }
  | _ => throw <| .configuration s!"unexpected uname output from {settings.image}: {out}"

/-- A running container, plus whether its image has `timeout(1)` — the in-container kill that
matches mini's process-group semantics. Minimal images may not, and then the host-side deadline
below is the only backstop. -/
private structure Container where
  id : String
  hasTimeout : Bool

/-- Starts the run's container with the working directory bind-mounted.

The mount is bound to that directory's inode, and a full (non-incremental) materialize replaces
it — `Store.materialize` removes the destination and recreates it. Both `resume` and `stepOnce`
check out once, before the first command, so the container is always started against the final
inode. Anything that re-materializes mid-run has to restart the container too. -/
private def start (settings : Settings) (workDir : System.FilePath) : IO Container := do
  let host ← IO.FS.realPath workDir
  let args := #["run", "--detach", "--rm", "--init", "--entrypoint", "/bin/sh"]
    ++ runArgs settings
    ++ #["--volume", s!"{host}:{workMount}", "--workdir", workMount]
    ++ settings.extraRunArgs
    ++ #[settings.image, "-c", "while :; do sleep 86400; done"]
  let started ← client args
  if started.exitCode != 0 then
    throw <| IO.userError s!"cannot start a container from {settings.image}: {started.stderr}"
  let id := started.stdout
  let probe ← client #["exec", id, "/bin/sh", "-c", "command -v timeout > /dev/null 2>&1"]
  pure { id, hasTimeout := probe.exitCode == 0 }

private def remove (id : String) : IO Unit := do
  let _ ← client #["rm", "--force", id]

/-! ## Running one command -/

/-- Mini's timeout observation, byte-identical to the local executor's. -/
private def timedOut (output display : String) (timeoutSeconds : Nat) : Output := {
  output, returncode := -1
  exceptionInfo := "An error occurred while executing the command: Command '" ++ display ++
    "' timed out after " ++ toString timeoutSeconds ++ " seconds" }

private def failed (message : String) : Output :=
  { output := "", returncode := -1,
    exceptionInfo := s!"An error occurred while executing the command: {message}" }

/-- The trampoline, with the in-container timeout when the image has one. The inner
`/bin/sh -c "$@"` still receives exactly mini's argv, so its error messages are unchanged. -/
private def script (config : Config) (hasTimeout : Bool) : String :=
  if hasTimeout && config.timeoutSeconds > 0 then
    s!"exec timeout -k 2 {config.timeoutSeconds} /bin/sh -c \"$@\" 2>&1"
  else "exec /bin/sh -c \"$@\" 2>&1"

private partial def poll (child : IO.Process.Child cfg) (readAll : IO String)
    (deadlineMs : Nat) : IO (Option UInt32 × String) := do
  match ← child.tryWait with
  | some code => pure (some code, ← readAll)
  | none =>
    if (← IO.monoMsNow) >= deadlineMs then
      child.kill
      let _ ← child.wait
      pure (none, ← readAll)
    else
      IO.sleep 20
      poll child readAll deadlineMs

/-- Docker's own failures (125, and 126/127 when it could not exec at all) come back on the
client's stderr, while the command's own output arrives on stdout with its stderr already
merged. A command may legitimately exit 126/127, so both signals are required. -/
private def clientFailure? (code : UInt32) (stderr : String) : Option String :=
  if (code == 125 || code == 126 || code == 127) && !stderr.isEmpty then some stderr else none

private def envArgs (config : Config) : Array String :=
  config.env.foldl (fun args (key, value) => args ++ #["--env", s!"{key}={value}"]) #[]

/-- Runs one command in the run's container, starting it on first use and after a timeout had to
take it down. Every failure is an observation, as mini never lets an execution problem end a
run. -/
private def execIn (ref : IO.Ref (Option Container)) (settings : Settings) (config : Config)
    (workDir : System.FilePath) (argv : Array String) (display : String) : IO Output := do
  try
    let container ← match ← ref.get with
      | some container => pure container
      | none =>
        let container ← start settings workDir
        ref.set (some container)
        pure container
    let child ← IO.Process.spawn {
      cmd := "docker"
      args := #["exec", "--interactive", "--workdir", workMount] ++ envArgs config
        ++ #[container.id, "/bin/sh", "-c", script config container.hasTimeout, "sh"] ++ argv
      stdin := .inherit, stdout := .piped, stderr := .piped }
    let outReader ← IO.asTask (prio := .dedicated) child.stdout.readBinToEnd
    let errReader ← IO.asTask (prio := .dedicated) child.stderr.readBinToEnd
    let readAll : IO String := do
      pure (lossyDecodeUtf8 ((← IO.wait outReader).toOption.getD ByteArray.empty))
    let start ← IO.monoMsNow
    -- With an in-container `timeout` the host deadline is only a backstop, so it allows for the
    -- kill grace; without one it is the whole mechanism and matches the local executor exactly.
    let graceMs := if container.hasTimeout then 5000 else 0
    let (code?, output) ← poll child readAll (start + config.timeoutSeconds * 1000 + graceMs)
    let elapsedMs := (← IO.monoMsNow) - start
    match code? with
    | none =>
      -- The client is gone but the command is still running inside; the container has to go.
      let _ ← client #["kill", container.id]
      remove container.id
      ref.set none
      pure (timedOut output display config.timeoutSeconds)
    | some code =>
      let stderr := lossyDecodeUtf8 ((← IO.wait errReader).toOption.getD ByteArray.empty)
      match clientFailure? code stderr.trimAscii.toString with
      | some message =>
        -- A container that died under us should not poison every later command.
        if (message.splitOn "is not running").length > 1 then ref.set none
        pure (failed message)
      | none =>
        -- How a killed command reports depends on the `timeout` in the image: GNU exits 124,
        -- busybox passes the signal status through (143 for TERM, 137 once `-k` sends KILL). A
        -- command can return any of those on its own, so a run that did not reach the limit is
        -- taken at its word.
        if (code == 124 || code == 137 || code == 143) &&
            elapsedMs >= config.timeoutSeconds * 1000 then
          pure (timedOut output display config.timeoutSeconds)
        else pure { output, returncode := Int.ofNat code.toNat }
  catch e =>
    pure (failed (toString e))

/-- An executor that runs every command of a run in one container, with the working directory
bind-mounted. `settings.image` should already be pinned, since it is what the trajectory
records. -/
def executor (settings : Settings) (config : Config) : Result Executor := do
  let ref ← Result.fromIO Error.storage (IO.mkRef (none : Option Container))
  pure {
    exec := execIn ref settings config
    uname := (uname settings).toUserIO
    image? := some settings.image
    close := do
      match ← ref.get with
      | some container => remove container.id; ref.set none
      | none => pure ()
  }

/-! ## Command line -/

/-- Settings for a given image, taking `--container-user` and `--network` from the line. -/
def settingsFor (args : Cli.Args) (image : String) : Result Settings := do
  let user? ← match args.get? "container-user" with
    | some user => pure (some user)
    | none => Result.fromIO Error.configuration defaultUser?
  pure { image, user?, network? := args.get? "network" }

/-- The container named on the command line, or `none` to run on the host. -/
def settings? (args : Cli.Args) : Result (Option Settings) := do
  match args.get? "image" with
  | none => pure none
  | some "" => throw <| .configuration "--image needs a value (e.g. --image python:3.12-slim)"
  | some image => some <$> settingsFor args image

end Alaya.Agent.MiniSwe.Docker
