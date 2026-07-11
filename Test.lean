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
  let parsed ← get <| Result.fromExcept Error.protocol <| Chat.Response.fromJson raw
  expectEqual "input tokens" (parsed.usage?.bind fun usage => usage.input?) (some 7)
  expectEqual "output tokens" (parsed.usage?.bind fun usage => usage.output?) (some 3)
  let schema := JsonSchema.object #[("city", .string)]
  let invalid : Chat.Response := { content? := some "not JSON", raw := .null }
  let error ← (Result.fromExcept Error.structuredOutput (invalid.structured schema)).toBaseIO
  match error with
  | .error (.structuredOutput _) => pure ()
  | _ => throw <| IO.userError "invalid structured response was not a typed error"

private def cacheAndBatchTests : IO Unit := do
  let (base, samples) ← mockModel
  let concurrent ← get <| base.batch .concurrent
  let responses ← get <| concurrent.completeN request 3
  expectEqual "concurrent response count" responses.size 3
  let directory : System.FilePath := ".lake/test-cache"
  if ← directory.pathExists then IO.FS.removeDirAll directory
  let persistent ← get <| Cache.persistent base { directory }
  let first ← get <| persistent.complete request
  let second ← get <| persistent.complete request
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

private def typedErrorTest : IO Unit := do
  let error ← (Result.fromExcept Error.protocol (Lean.Json.parse "not json")).toBaseIO
  match error with
  | .error (.protocol _) => pure ()
  | _ => throw <| IO.userError "invalid JSON was not a typed protocol error"

def main : IO Unit := do
  protocolTests
  cacheAndBatchTests
  retryTests
  typedErrorTest
  IO.println "All tests passed."
