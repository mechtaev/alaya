import Alaya.Error

namespace Alaya.Retry

structure Config where
  maxAttempts : Nat := 3
  /-- Attempt budget for rate-limited (HTTP 429) failures. A rate limit signals throttling
  rather than failure and clears once the provider sheds load, so it deserves more patience
  than a genuine error; the effective budget is `max maxAttempts rateLimitMaxAttempts`.
  Setting `maxAttempts := 1` disables retries for every failure class, including this one. -/
  rateLimitMaxAttempts : Nat := 8
  initialDelayMs : Nat := 250
  maxDelayMs : Nat := 10000
  /-- Backoff floor for a rate-limited failure without a server-supplied delay: a saturated
  provider rarely recovers within a sub-second backoff, so start the exponential schedule
  from seconds instead. `maxDelayMs` still caps the resulting delay. -/
  rateLimitFloorMs : Nat := 2000
  /-- Cap for the total sleep honoring a server-supplied `Retry-After` delay, jitter included.
  Server delays are clamped to this bound rather than to `maxDelayMs`, which only caps
  locally computed backoff; retrying before the server-requested time guarantees another
  rejection. -/
  maxRetryAfterMs : Nat := 60000
  retryUnknownDelivery : Bool := false
  /-- Retry a fresh completion when the model response fails structured-output validation. -/
  retryStructuredOutput : Bool := false
  /-- Retry a fresh completion when a response cannot be parsed as a valid completion. -/
  retryMalformedResponse : Bool := false
  /-- Uniform jitter as a fraction of an exponential backoff delay. Server-supplied delays
  are jittered upward only, so concurrent requests released by the same `Retry-After` do
  not stampede the provider into rejecting them all again. -/
  jitter : Float := 0.2

/-- A rate-limited request was refused to shed load, not because it is faulty. -/
private def rateLimited : Error -> Bool
  | .http 429 _ _ => true
  | _ => false

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

/-- The attempt budget for rate-limited failures. Rate limits get the larger budget, except
that `maxAttempts := 1` means "never retry" for every failure class. -/
private def rateLimitBudget (config : Config) : Nat :=
  if config.maxAttempts == 1 then 1
  else max config.maxAttempts config.rateLimitMaxAttempts

/-- Uses the provider's `Retry-After` delay when available, otherwise capped exponential backoff.

`attempt` counts prior failures of the same class as `error`, so one class's backoff schedule
does not accelerate another's. Rate-limited failures without a server-supplied delay back off
from `rateLimitFloorMs` rather than `initialDelayMs`. -/
private def delayMs (config : Config) (attempt : Nat) (error : Error) : Result Nat := do
  let spread := max 0 (min 1 config.jitter)
  match error with
  | .http _ _ (some delay) =>
    let delay := min config.maxRetryAfterMs delay
    -- Upward-only jitter, kept within the cap: never retry before the delay the server asked
    -- for, and never sleep past maxRetryAfterMs either.
    let upper := min config.maxRetryAfterMs ((delay.toFloat * (1 + spread)).toUInt64.toNat)
    Result.fromIO Error.transport <| IO.rand delay (max delay upper)
  | _ =>
    let initial :=
      if rateLimited error then max config.initialDelayMs config.rateLimitFloorMs
      else config.initialDelayMs
    let backoff := min config.maxDelayMs <| initial * 2 ^ attempt
    let lower := (backoff.toFloat * (1 - spread)).toUInt64.toNat
    let upper := (backoff.toFloat * (1 + spread)).toUInt64.toNat
    Result.fromIO Error.transport <| IO.rand lower upper

/-- Repeats a typed action when its configured policy considers the failure transient.

Failures are budgeted per class: rate limits draw on `rateLimitBudget` while every other
retryable failure draws on `maxAttempts`, each counted separately, so a burst of 429s cannot
exhaust the patience reserved for genuine transient errors, and vice versa. -/
def run (config : Config) (action : Result alpha) : Result alpha := do
  if config.maxAttempts == 0 then
    throw <| .configuration "retry maxAttempts must be at least one"
  let rec go (general rate : Nat) : (fuel : Nat) -> Result alpha
    -- Unreachable: fuel is the sum of both class budgets, so one class exhausts its budget
    -- (throwing below) before fuel can run out.
    | 0 => action
    | fuel + 1 => do
      try action
      catch error =>
        let isRateLimit := rateLimited error
        let failures := (if isRateLimit then rate else general) + 1
        let budget := if isRateLimit then rateLimitBudget config else config.maxAttempts
        if !retryable config error || failures >= budget then throw error
        let delay ← delayMs config (failures - 1) error
        let _ ← Result.fromIO Error.transport <| IO.sleep delay.toUInt32
        if isRateLimit then go general (rate + 1) fuel else go (general + 1) rate fuel
  go 0 0 (config.maxAttempts + rateLimitBudget config)

end Alaya.Retry
