import Alaya.Error

namespace Alaya.Retry

structure Config where
  maxAttempts : Nat := 3
  initialDelayMs : Nat := 250
  maxDelayMs : Nat := 10000
  retryUnknownDelivery : Bool := false
  /-- Retry a fresh completion when the model response fails structured-output validation. -/
  retryStructuredOutput : Bool := false
  /-- Retry a fresh completion when a response cannot be parsed as a valid completion. -/
  retryMalformedResponse : Bool := false
  /-- Uniform jitter as a fraction of an exponential backoff delay. -/
  jitter : Float := 0.2

/-- Determines whether retrying is safe and likely useful.

Retry known transient HTTP statuses. Transport failures are opt-in because the server may have
received and processed the request before the connection failed. Structured-output validation
failures are also opt-in: another sample can satisfy the schema, but a bad schema or prompt will
fail repeatedly. Malformed-response failures are opt-in for the same reason: a truncated or garbled
body may parse on a retry, but a genuine protocol mismatch will not. Configuration, provider, cache,
and cancellation failures are terminal. -/
private def retryable (config : Config) : Error -> Bool
  | .http status _ _ => status == 408 || status == 409 || status == 425 || status == 429 ||
      (500 <= status && status < 600)
  | .transport _ => config.retryUnknownDelivery
  | .structuredOutput _ => config.retryStructuredOutput
  | .protocol _ => config.retryMalformedResponse
  | _ => false

/-- Uses the provider's `Retry-After` delay when available, otherwise capped exponential backoff. -/
private def delayMs (config : Config) (attempt : Nat) (error : Error) : Result Nat :=
  match error with
  | .http _ _ (some delay) => pure <| min config.maxDelayMs delay
  | _ => do
    let backoff := min config.maxDelayMs <| config.initialDelayMs * 2 ^ attempt
    let spread := max 0 (min 1 config.jitter)
    let lower := (backoff.toFloat * (1 - spread)).toUInt64.toNat
    let upper := (backoff.toFloat * (1 + spread)).toUInt64.toNat
    let value ← Result.fromIO Error.transport <| IO.rand lower upper
    pure value

/-- Repeats a typed action when its configured policy considers the failure transient. -/
def run (config : Config) (action : Result alpha) : Result alpha :=
  let rec go (attempt : Nat) : (remaining : Nat) -> Result alpha
    | 0 => throw <| .configuration "retry maxAttempts must be at least one"
    | 1 => action
    | remaining + 1 => do
      try action
      catch error =>
        if !retryable config error then throw error
        let delay ← delayMs config attempt error
        let _ ← Result.fromIO Error.transport <| IO.sleep delay.toUInt32
        go (attempt + 1) remaining
  go 0 config.maxAttempts

end Alaya.Retry
