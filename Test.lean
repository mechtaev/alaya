import Alaya.Cache
import Alaya.Chat.Schema
import Alaya.Model

open Lean
open Alaya
open Alaya.Chat

private def expectEqual [BEq alpha] (name : String) (actual expected : alpha) : IO Unit := do
  if actual != expected then throw <| IO.userError s!"{name}: unexpected result"

private def get (result : Result alpha) : IO alpha :=
  result.toIO fun error => IO.userError s!"{repr error}"

private def response (value : Nat) : Chat.Response :=
  { content? := some (toString value), raw := .null }

private def mockModel : IO (Model × IO Nat) := do
  let count ← IO.mkRef 0
  let model : Model := {
    identity := .mkObj [("model", "test"), ("temperature", 1)]
    sample := fun _ => do
      pure { next := do
        let value ← Result.fromIO Error.cache <| count.modifyGet fun value => (value, value + 1)
        pure <| response value }
  }
  pure (model, count.get)

private def request : Chat.Request := { messages := #[.user "prompt"] }

private def protocolTests : IO Unit := do
  let raw := Json.mkObj [
    ("choices", .arr #[.mkObj [("message", .mkObj [("content", "hello")])]]),
    ("usage", .mkObj [("prompt_tokens", 7), ("completion_tokens", 3), ("total_tokens", 10)])
  ]
  let parsed ← get <| Chat.Response.fromJson raw
  expectEqual "input tokens" (parsed.usage?.bind fun usage => usage.input?) (some 7)
  expectEqual "output tokens" (parsed.usage?.bind fun usage => usage.output?) (some 3)
  let schema := JsonSchema.object #[("city", .string)]
  let invalid : Chat.Response := { content? := some "not JSON", raw := .null }
  let error ← (invalid.structured schema).toBaseIO
  match error with
  | .error (.structuredOutput _) => pure ()
  | _ => throw <| IO.userError "invalid structured response was not a typed error"

private def toolCallTests : IO Unit := do
  -- A present-but-null `tool_calls` field must parse as an empty tool-call list, not fail.
  let withNullToolCalls := Json.mkObj [
    ("choices", .arr #[.mkObj [("message", .mkObj [("content", "hi"), ("tool_calls", .null)])]])
  ]
  let parsed ← get <| Chat.Response.fromJson withNullToolCalls
  expectEqual "null tool_calls content" parsed.content? (some "hi")
  expectEqual "null tool_calls count" parsed.toolCalls.size 0
  -- A well-formed tool call is parsed with its arguments decoded from the JSON string.
  let withToolCall := Json.mkObj [
    ("choices", .arr #[.mkObj [("message", .mkObj [
      ("content", .null),
      ("tool_calls", .arr #[.mkObj [
        ("id", "call_1"),
        ("type", "function"),
        ("function", .mkObj [("name", "get_weather"), ("arguments", "{\"city\":\"Paris\"}")])
      ]])
    ])]])
  ]
  let call ← get <| Chat.Response.fromJson withToolCall
  expectEqual "tool call count" call.toolCalls.size 1
  expectEqual "tool call id" (call.toolCalls[0]?.map ToolCall.id) (some "call_1")
  expectEqual "tool call name" (call.toolCalls[0]?.map ToolCall.name) (some "get_weather")
  expectEqual "tool call argument"
    (call.toolCalls[0]?.bind fun c => (c.arguments.getObjVal? "city" >>= Json.getStr?).toOption)
    (some "Paris")

private def structuredOutputTests : IO Unit := do
  let schema := JsonSchema.object #[("city", .string)]
  -- Native structured output parses and validates the raw content directly.
  let native : Chat.Response := { content? := some "{\"city\": \"Paris\"}", raw := .null }
  let value ← get <| native.structured schema
  expectEqual "native structured city"
    ((value.getObjVal? "city" >>= Json.getStr?).toOption) (some "Paris")
  -- The markdown-code-fence fallback extracts the JSON from a fenced block before validating.
  let fenced : Chat.Response := {
    content? := some "Sure:\n```json\n{\"city\": \"Paris\"}\n```\nDone."
    raw := .null
    structuredOutput := .markdownCodeFence
  }
  let fencedValue ← get <| fenced.structured schema
  expectEqual "fenced structured city"
    ((fencedValue.getObjVal? "city" >>= Json.getStr?).toOption) (some "Paris")
  -- A value that violates the schema is rejected as a typed structured-output error.
  let wrong : Chat.Response := { content? := some "{\"city\": 7}", raw := .null }
  let error ← (wrong.structured schema).toBaseIO
  match error with
  | .error (.structuredOutput _) => pure ()
  | _ => throw <| IO.userError "schema-violating response was not a typed error"

private def cacheAndBatchTests : IO Unit := do
  let (base, samples) ← mockModel
  let concurrent ← get <| base.batch .concurrent
  let stream ← get <| concurrent.sample request
  let responses ← get <| stream.nextN 3
  expectEqual "concurrent response count" responses.size 3
  let directory : System.FilePath := ".lake/test-cache"
  if ← directory.pathExists then IO.FS.removeDirAll directory
  let persistent ← get <| Cache.persistent base { directory }
  -- Each fresh stream replays the persisted sequence from the start; only the first miss samples.
  let firstStream ← get <| persistent.sample request
  let first ← get firstStream.next
  let secondStream ← get <| persistent.sample request
  let second ← get secondStream.next
  expectEqual "persistent replay" first.content? second.content?
  expectEqual "persistent samples once" (← samples) 4

private def retryTests : IO Unit := do
  let attempts ← IO.mkRef 0
  let action : Result Nat := do
    let attempt ← Result.fromIO Error.cache <| attempts.modifyGet fun value => (value, value + 1)
    if attempt < 2 then throw <| .http 429 "rate limited" none else pure 42
  let value ← get <| Retry.run { maxAttempts := 3, initialDelayMs := 0 } action
  expectEqual "retry succeeds" value 42
  expectEqual "retry attempt count" (← attempts.get) 3
  let exhausted ← IO.mkRef 0
  let failure : Result Unit := do
    let _ ← Result.fromIO Error.cache <| exhausted.modify (· + 1)
    throw <| .http 503 "unavailable" none
  let result ← (Retry.run { maxAttempts := 3, initialDelayMs := 0 } failure).toBaseIO
  match result with
  | .error (.http 503 _ _) => pure ()
  | _ => throw <| IO.userError "retry exhaustion returned the wrong result"
  expectEqual "retry exhaustion count" (← exhausted.get) 3
  let structuredAttempts ← IO.mkRef 0
  let structuredFailure : Result Unit := do
    let _ ← Result.fromIO Error.cache <| structuredAttempts.modify (· + 1)
    throw <| .structuredOutput "invalid JSON"
  let structuredResult ← (Retry.run {
    maxAttempts := 2, initialDelayMs := 0, retryStructuredOutput := true
  } structuredFailure).toBaseIO
  match structuredResult with
  | .error (.structuredOutput _) => pure ()
  | _ => throw <| IO.userError "structured-output retry returned the wrong result"
  expectEqual "structured-output retry count" (← structuredAttempts.get) 2
  -- A malformed (protocol) response is terminal by default.
  let malformedDefault ← IO.mkRef 0
  let malformed : Result Unit := do
    let _ ← Result.fromIO Error.cache <| malformedDefault.modify (· + 1)
    throw <| .protocol "truncated response body"
  let terminal ← (Retry.run { maxAttempts := 3, initialDelayMs := 0 } malformed).toBaseIO
  match terminal with
  | .error (.protocol _) => pure ()
  | _ => throw <| IO.userError "malformed response should be terminal by default"
  expectEqual "malformed default attempt count" (← malformedDefault.get) 1
  -- With the opt-in flag, a malformed response is retried like a fresh sample.
  let malformedRetries ← IO.mkRef 0
  let malformedRetried : Result Unit := do
    let _ ← Result.fromIO Error.cache <| malformedRetries.modify (· + 1)
    throw <| .protocol "truncated response body"
  let retriedResult ← (Retry.run {
    maxAttempts := 3, initialDelayMs := 0, retryMalformedResponse := true
  } malformedRetried).toBaseIO
  match retriedResult with
  | .error (.protocol _) => pure ()
  | _ => throw <| IO.userError "malformed-response retry returned the wrong result"
  expectEqual "malformed retry attempt count" (← malformedRetries.get) 3
  -- A hostile `Retry-After` must be capped at maxDelayMs rather than stalling the retry loop.
  let capAttempts ← IO.mkRef 0
  let start ← IO.monoMsNow
  let capped : Result Nat := do
    let attempt ← Result.fromIO Error.cache <| capAttempts.modifyGet fun value => (value, value + 1)
    if attempt < 1 then throw <| .http 429 "rate limited" (some 600000) else pure 7
  let value ← get <| Retry.run { maxAttempts := 2, initialDelayMs := 0, maxDelayMs := 5 } capped
  let elapsed := (← IO.monoMsNow) - start
  expectEqual "retry-after cap value" value 7
  if elapsed > 2000 then
    throw <| IO.userError s!"Retry-After was not capped at maxDelayMs: slept {elapsed}ms"

private def typedErrorTest : IO Unit := do
  let error ← (Result.fromExcept Error.protocol (Lean.Json.parse "not json")).toBaseIO
  match error with
  | .error (.protocol _) => pure ()
  | _ => throw <| IO.userError "invalid JSON was not a typed protocol error"

private def independenceTests : IO Unit := do
  -- `repeatable`: two streams for the same prompt replay one shared sequence, so five draws across
  -- the streams cost only three underlying samples.
  let (base, samples) ← mockModel
  let repeatable ← get base.repeatable
  let s1 ← get <| repeatable.sample request
  let s2 ← get <| repeatable.sample request
  expectEqual "repeatable s1 first" (← get s1.next).content? (some "0")
  expectEqual "repeatable s2 first" (← get s2.next).content? (some "0")
  expectEqual "repeatable s1 second" (← get s1.next).content? (some "1")
  expectEqual "repeatable s2 second" (← get s2.next).content? (some "1")
  expectEqual "repeatable s1 third" (← get s1.next).content? (some "2")
  expectEqual "repeatable underlying samples" (← samples) 3
  -- Each fresh `sample` call over a `repeatable` model restarts the replay from the beginning.
  let (statelessBase, _) ← mockModel
  let stateless ← get statelessBase.repeatable
  let first ← get <| stateless.sample request
  expectEqual "stateless first draw" (← get first.next).content? (some "0")
  expectEqual "stateless second draw" (← get first.next).content? (some "1")
  let restart ← get <| stateless.sample request
  expectEqual "stateless fresh stream replays" (← get restart.next).content? (some "0")
  -- `independent`: the shared sequence keeps advancing across freshly-wrapped `repeatable` views,
  -- so a later view draws fresh samples ("2","3") instead of replaying the earlier ones ("0","1").
  let (mock, mockSamples) ← mockModel
  let cached ← get mock.repeatable
  let shared ← get cached.independent
  let mut draws : Array String := #[]
  for _ in [0:2] do
    let view ← get shared.repeatable
    let a ← get <| view.sample request
    let b ← get <| view.sample request
    draws := draws.push ((← get a.next).content?.getD "?")
    draws := draws.push ((← get b.next).content?.getD "?")
    draws := draws.push ((← get a.next).content?.getD "?")
  expectEqual "independent advancing draws" draws #["0", "0", "1", "2", "2", "3"]
  expectEqual "independent underlying samples" (← mockSamples) 4

def main : IO Unit := do
  protocolTests
  toolCallTests
  structuredOutputTests
  cacheAndBatchTests
  retryTests
  typedErrorTest
  independenceTests
  IO.println "All tests passed."
