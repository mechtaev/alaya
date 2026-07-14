import Alaya.Model
import Std.Sync.Mutex

namespace Alaya.Cache

structure Config where
  directory : System.FilePath
  readOnly : Bool := false

private def usageToJson : Chat.TokenUsage -> Lean.Json
  | { input?, output?, total? } => .mkObj [
    ("input", input?.map Lean.Json.num |>.getD .null),
    ("output", output?.map Lean.Json.num |>.getD .null),
    ("total", total?.map Lean.Json.num |>.getD .null)
  ]

private def responseToJson (response : Chat.Response) : Lean.Json :=
  .mkObj [
    ("content", response.content?.map Lean.Json.str |>.getD .null),
    ("tool_calls", .arr <| response.toolCalls.map fun call => .mkObj [
      ("id", call.id),
      ("name", call.name),
      ("arguments", call.arguments)
    ]),
    ("usage", response.usage?.map usageToJson |>.getD .null)
  ]

private def responsesToJson (key : String) (responses : Array Chat.Response) : Lean.Json :=
  .mkObj [
    ("version", 1),
    ("key", key),
    ("responses", .arr <| responses.map responseToJson)
  ]

private def liftJson (error : String) (result : Except String alpha) : Except String alpha :=
  result.mapError fun _ => error

private def usageFromJson? (json : Lean.Json) : Option Chat.TokenUsage :=
  match json.getObjVal? "usage" with
  | .ok usage =>
    let input? := (usage.getObjVal? "input" >>= Lean.Json.getNat?).toOption
    let output? := (usage.getObjVal? "output" >>= Lean.Json.getNat?).toOption
    let total? := (usage.getObjVal? "total" >>= Lean.Json.getNat?).toOption
    some { input?, output?, total? }
  | .error _ => none

private def responseFromJson (json : Lean.Json) : Except String Chat.Response := do
  let content? := (json.getObjVal? "content" >>= Lean.Json.getStr?).toOption
  let calls ← liftJson "cached response has invalid tool calls" <| json.getObjVal? "tool_calls" >>= Lean.Json.getArr?
  let toolCalls ← calls.mapM fun call => do
    let id ← liftJson "cached tool call has no id" <| call.getObjVal? "id" >>= Lean.Json.getStr?
    let name ← liftJson "cached tool call has no name" <| call.getObjVal? "name" >>= Lean.Json.getStr?
    let arguments ← liftJson "cached tool call has no arguments" <| call.getObjVal? "arguments"
    pure { id, name, arguments }
  let usage? := usageFromJson? json
  pure { content?, toolCalls, usage?, raw := .null }

private def responsesFromJson (key : String) (json : Lean.Json) : Except String (Array Chat.Response) := do
  let version ← liftJson "cached entry has no version" <| json.getObjVal? "version" >>= Lean.Json.getNat?
  if version != 1 then throw "cached entry has an unsupported version"
  let storedKey ← liftJson "cached entry has no key" <| json.getObjVal? "key" >>= Lean.Json.getStr?
  if storedKey != key then throw "cached entry key does not match its filename"
  let responses ← liftJson "cached entry has no responses" <| json.getObjVal? "responses" >>= Lean.Json.getArr?
  responses.mapM responseFromJson

private def fileName (key : String) : String :=
  s!"{hash key}.json"

private def entryPath (config : Config) (key : String) : System.FilePath :=
  config.directory / "v1" / fileName key

private def load (config : Config) (key : String) : IO (Array Chat.Response) := do
  let path := entryPath config key
  if !(← path.pathExists) then return #[]
  try
    let contents ← IO.FS.readFile path
    let json ← IO.ofExcept <| liftJson "cached entry is invalid JSON" <| Lean.Json.parse contents
    IO.ofExcept <| responsesFromJson key json
  catch _ =>
    -- A corrupt entry is treated as a miss and replaced on the next successful sample.
    pure #[]

private def save (config : Config) (key : String) (responses : Array Chat.Response) : IO Unit := do
  let path := entryPath config key
  let directory := path.parent.getD config.directory
  IO.FS.createDirAll directory
  let temporary := path.withExtension "tmp"
  IO.FS.writeFile temporary <| (responsesToJson key responses).pretty
  IO.FS.rename temporary path

/-- Runs a cache-backing IO action, mapping any failure to a typed cache error. -/
private def io (action : IO α) : Result α :=
  Result.fromIO Error.cache action

/-- Replays response sequences from disk and extends them on cache misses.

Concurrent streams in this process serialize extensions of the same cache entry. Cache directories
must not be written by more than one process at a time. -/
def persistent (inner : Model) (config : Config) : Result Model := do
  let entries ← io <| Std.Mutex.new ({} : Std.HashMap String (Std.Mutex (Array Chat.Response)))
  pure {
    identity := inner.identity
    structuredOutput := inner.structuredOutput
    sample := fun request => do
      let key := inner.cacheKey request
      let loaded ← io <| load config key
      let entry ← entries.atomically fun entries => do
        match (← entries.get).get? key with
        | some entry => pure entry
        | none =>
          let entry ← io <| Std.Mutex.new loaded
          entries.modify fun entries => entries.insert key entry
          pure entry
      let index ← io <| IO.mkRef 0
      let nextN (n : Nat) : Result (Array Chat.Response) := do
        let responses ← entry.atomically fun responses => do
          let current ← io index.get
          let allResponses ← io responses.get
          let cached := (List.range n).foldl (fun cached offset =>
            match allResponses[current + offset]? with
            | some response => cached.push response
            | none => cached) #[]
          let missing := n - cached.size
          if missing == 0 then
            let _ ← io <| index.set (current + n)
            pure cached
          else if config.readOnly then
            throw <| .cache "persistent cache miss in read-only mode"
          else
            let sampled ← (← inner.sample request).nextN missing
            if sampled.size != missing then
              throw <| .protocol "model returned the wrong number of responses"
            let _ ← io <| responses.modify fun responses => responses ++ sampled
            let saved ← io responses.get
            let _ ← io <| save config key saved
            let _ ← io <| index.set (current + n)
            pure <| cached ++ sampled
        -- Responses loaded from disk carry no mode, so stamp the model's structured-output mode
        -- here, at the single point where responses leave the cache.
        pure <| responses.map fun response => { response with structuredOutput := inner.structuredOutput }
      let next : Result Chat.Response := do
        let responses ← nextN 1
        match responses[0]? with
        | some response => pure response
        | none => throw <| .protocol "model returned no responses"
      pure { next, nextN? := some nextN }
  }

end Alaya.Cache
