namespace Alaya

inductive Error where
  /-- Invalid local Alaya configuration, such as a missing API key or non-finite temperature. -/
  | configuration (message : String)
  /-- The request could not be delivered or its result is unknown; retrying may duplicate work. -/
  | transport (message : String)
  /-- A provider returned an HTTP response; the status and body support retry and diagnostics. -/
  | http (status : Nat) (body : String) (retryAfterMs? : Option Nat := none)
  /-- A provider-specific failure not represented by transport, HTTP, or protocol failures. -/
  | provider (message : String)
  /-- A response or local wire representation did not satisfy the expected chat protocol. -/
  | protocol (message : String)
  /-- The response did not satisfy the requested structured-output contract. -/
  | structuredOutput (message : String)
  /-- Reading, extending, or atomically persisting a cache entry failed. -/
  | cache (message : String)
  /-- The operation was intentionally cancelled. -/
  | cancelled
  deriving Repr, Inhabited

abbrev Result (alpha : Type) := EIO Error alpha

namespace Result

def fromIO (kind : String -> Error) (action : IO alpha) : Result alpha := do
  match ← action.toBaseIO with
  | .ok value => pure value
  | .error error => throw <| kind error.toString

def fromExcept (kind : String -> Error) (result : Except String alpha) : Result alpha :=
  match result with
  | .ok value => pure value
  | .error error => throw <| kind error

end Result
end Alaya
