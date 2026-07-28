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
  /-- Reading or writing the content-addressed store, or a filesystem snapshot, failed. -/
  | storage (message : String)
  /-- The operation was intentionally cancelled. -/
  | cancelled
  deriving Repr, Inhabited

/-- One line naming the failure, for a command-line front end. -/
def Error.describe : Error -> String
  | .configuration m => m
  | .transport m => s!"transport: {m}"
  | .http status body _ => s!"http {status}: {body}"
  | .provider m => s!"provider: {m}"
  | .protocol m => s!"protocol: {m}"
  | .structuredOutput m => s!"structured output: {m}"
  | .cache m => s!"cache: {m}"
  | .storage m => s!"storage: {m}"
  | .cancelled => "cancelled"

abbrev Result (α : Type) := EIO Error α

namespace Result

def fromIO (kind : String -> Error) (action : IO α) : Result α := do
  match ← action.toBaseIO with
  | .ok value => pure value
  | .error error => throw <| kind error.toString

def fromExcept (kind : String -> Error) (result : Except String α) : Result α :=
  match result with
  | .ok value => pure value
  | .error error => throw <| kind error

/-- Runs a typed action in plain `IO`, rendering any typed failure as a user error. -/
def toUserIO (result : Result α) : IO α :=
  result.toIO fun error => IO.userError s!"{repr error}"

end Result
end Alaya
