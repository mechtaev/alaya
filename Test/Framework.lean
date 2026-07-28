import Alaya.Error

/-!
A small test framework for reproducible, convenient IO tests.

Each test case runs with a fresh scratch directory (recreated before the run, so failures leave
their state behind for inspection), failures are collected rather than aborting the run, and the
runner accepts a substring filter so a single suite or case can be re-run in isolation:
`lake exe tests -- <substring>`.
-/

namespace Testing

open Alaya (Result Error)

/-- Everything a running test can reach: its full name and its private scratch directory. -/
structure Context where
  name : String
  scratch : System.FilePath

abbrev TestM := ReaderT Context IO

/-- Byte arrays print as byte lists in assertion failures. -/
instance : Repr ByteArray := ⟨fun bytes precedence => reprPrec bytes.toList precedence⟩

structure Case where
  name : String
  run : Context -> IO Unit

structure Suite where
  name : String
  cases : Array Case

def test (name : String) (body : TestM Unit) : Case :=
  { name, run := fun context => body.run context }

/-- Wraps a plain `IO Unit` test that does not need a scratch directory. -/
def iotest (name : String) (body : IO Unit) : Case :=
  { name, run := fun _ => body }

def suite (name : String) (cases : Array Case) : Suite :=
  { name, cases }

/-- The test's private scratch directory, fresh at the start of the run. -/
def scratch : TestM System.FilePath :=
  return (← read).scratch

def fail (message : String) : TestM alpha := do
  throw <| IO.userError s!"{(← read).name}: {message}"

def check (condition : Bool) (message : String) : TestM Unit := do
  if !condition then fail message

def assertEqual [BEq alpha] [Repr alpha] (label : String) (actual expected : alpha) : TestM Unit := do
  if actual != expected then
    fail s!"{label}: expected {repr expected}, got {repr actual}"

/-- Runs a typed action, failing the test on a typed error. -/
def assertOk (result : Result alpha) : TestM alpha := do
  match ← result.toBaseIO with
  | .ok value => pure value
  | .error error => fail s!"unexpected typed error: {repr error}"

/-- Asserts that a typed action fails with an error accepted by `accepts`. -/
def assertError (label : String) (result : Result alpha) (accepts : Error -> Bool) : TestM Unit := do
  match ← result.toBaseIO with
  | .ok _ => fail s!"{label}: expected an error, got a value"
  | .error error =>
    if !accepts error then fail s!"{label}: wrong error: {repr error}"

/-- Deterministic pseudo-random bytes (a linear congruential generator), so tests that need
"arbitrary" content are reproducible across runs and machines. -/
def deterministicBytes (seed length : Nat) : ByteArray := Id.run do
  let mut state := seed * 2654435761 + 1013904223
  let mut bytes := ByteArray.emptyWithCapacity length
  for _ in [0:length] do
    state := (state * 6364136223846793005 + 1442695040888963407) % (2 ^ 64)
    bytes := bytes.push (UInt8.ofNat ((state >>> 33) % 256))
  return bytes

/-- Creates the given files under `base`, making parent directories as needed. Paths are
`/`-separated and relative; contents are written verbatim. -/
def writeSpec (base : System.FilePath) (files : Array (String × String)) : IO Unit := do
  for (path, content) in files do
    let destination := base / (path : System.FilePath)
    IO.FS.createDirAll (destination.parent.getD base)
    IO.FS.writeFile destination content

private partial def readSpecInto (base : System.FilePath) (relative : String)
    (accumulated : Array (String × String)) : IO (Array (String × String)) := do
  let directory := if relative.isEmpty then base else base / (relative : System.FilePath)
  let children ← directory.readDir
  children.foldlM (init := accumulated) fun accumulated child => do
    let path := if relative.isEmpty then child.fileName else s!"{relative}/{child.fileName}"
    match (← child.path.symlinkMetadata).type with
    | .dir => readSpecInto base path accumulated
    | .symlink =>
      let out ← IO.Process.output { cmd := "readlink", args := #[child.path.toString] }
      pure (accumulated.push (path, s!"-> {out.stdout.trimAscii}"))
    | _ => pure (accumulated.push (path, ← IO.FS.readFile child.path))

/-- Reads every regular file under `base` back into sorted `(path, content)` pairs, for
comparing a directory against a `writeSpec`. Symlinks are listed as `(path, "-> target")`. -/
def readSpec (base : System.FilePath) : IO (Array (String × String)) := do
  let entries ← readSpecInto base "" #[]
  pure (entries.qsort fun a b => compare a.1 b.1 == .lt)

/-- Marks a file executable (user+group+other read, user write/execute). -/
def setExecutable (path : System.FilePath) : IO Unit :=
  IO.setAccessRights path {
    user := { read := true, write := true, execution := true }
    group := { read := true, execution := true }
    other := { read := true, execution := true }
  }

def isExecutable (path : System.FilePath) : IO Bool := do
  let out ← IO.Process.output { cmd := "test", args := #["-x", path.toString] }
  pure (out.exitCode == 0)

def createSymlink (target : String) (path : System.FilePath) : IO Unit := do
  let out ← IO.Process.output { cmd := "ln", args := #["-s", target, path.toString] }
  if out.exitCode != 0 then throw <| IO.userError s!"ln -s failed: {out.stderr}"

def readSymlink (path : System.FilePath) : IO String := do
  let out ← IO.Process.output { cmd := "readlink", args := #[path.toString] }
  if out.exitCode != 0 then throw <| IO.userError s!"readlink failed: {out.stderr}"
  pure out.stdout.trimAscii.toString

/-- Runs the suites, printing progress and a final summary; returns the number of failures.
`filter?` keeps only cases whose `suite/case` name contains the substring. -/
def runSuites (suites : Array Suite) (filter? : Option String := none) : IO UInt32 := do
  let scratchRoot : System.FilePath := ".lake" / "test-scratch"
  let mut passed := 0
  let mut failures : Array (String × String) := #[]
  for suite in suites do
    for case in suite.cases do
      let name := s!"{suite.name}/{case.name}"
      if let some filter := filter? then
        if (name.splitOn filter).length < 2 then continue
      let slug := name.map fun c => if c.isAlphanum || c == '-' || c == '.' then c else '_'
      let scratch := scratchRoot / slug
      if ← scratch.pathExists then IO.FS.removeDirAll scratch
      IO.FS.createDirAll scratch
      match ← (case.run { name, scratch }).toBaseIO with
      | .ok () => passed := passed + 1
      | .error error =>
        failures := failures.push (name, error.toString)
        IO.eprintln s!"FAIL {name}: {error}"
  if failures.isEmpty then
    IO.println s!"All {passed} tests passed."
  else
    IO.eprintln s!"\n{failures.size} of {passed + failures.size} tests failed:"
    for (name, message) in failures do
      IO.eprintln s!"  {name}: {message}"
  pure (UInt32.ofNat (min failures.size 255))

end Testing
