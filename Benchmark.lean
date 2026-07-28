import Alaya

/-! `benchmark` — throughput comparison across providers and models. See README.md. -/

open Alaya
open Alaya.Chat

private def usage : String :=
  "usage: benchmark --model PROVIDER:NAME [--model PROVIDER:NAME ...] [--count N] " ++
  "[--temperature T] [--concurrent [N]] [--prompt TEXT | --prompt-file F] [--url U] [--port N]"

/-- The default task, sized to produce a few hundred output tokens. -/
private def defaultPrompt : String :=
  "Implement a complete, well-documented Python `LRUCache` class supporting `get` and `put` in \
   O(1), with docstrings, type hints, and three usage examples."

private def emit (s : String) : Result Unit := Result.fromIO Error.storage (IO.println s)

private def now : Result Nat := Result.fromIO Error.storage IO.monoMsNow

/-- Output tokens for a response, preferring the provider's reported count. -/
private def outputTokens (response : Response) : Option Nat :=
  response.usage?.bind (·.output?)

/-- Falls back to a rough character-based estimate when a provider omits usage. -/
private def approxTokens (response : Response) : Nat :=
  match outputTokens response with
  | some tokens => tokens
  | none => (response.content?.getD "").length / 4

/-- One timed phase for one model. -/
private structure Measurement where
  spec : String
  phase : String
  requests : Nat
  tokens : Nat
  ms : Nat
  /-- Whether any response lacked provider-reported usage, making `tokens` an estimate. -/
  approximate : Bool

private def Measurement.rate (m : Measurement) : Nat :=
  if m.ms == 0 then 0 else m.tokens * 1000 / m.ms

private def Measurement.of (spec phase : String) (responses : Array Response) (ms : Nat) :
    Measurement := {
  spec, phase, ms
  requests := responses.size
  tokens := responses.foldl (fun total response => total + approxTokens response) 0
  approximate := responses.any fun response => (outputTokens response).isNone
}

/-- `toString` on a `Float` pads to six decimals; trim them for the header line. -/
private def showFloat (x : Float) : String :=
  let trimmed := ((toString x).dropEndWhile (· == '0')).toString
  if trimmed.endsWith "." then trimmed ++ "0" else trimmed

private def padRight (s : String) (width : Nat) : String := s ++ "".pushn ' ' (width - s.length)
private def padLeft (s : String) (width : Nat) : String := "".pushn ' ' (width - s.length) ++ s

/-- Measures one model: a sequential phase always, then a concurrent phase when asked for.
`concurrent?` is `some limit?`, where `limit?` bounds how many requests are in flight. -/
private def measureModel (spec : String) (options : Provider.Options) (temperature : Float)
    (count : Nat) (concurrent? : Option (Option Nat)) (prompt : Request) :
    Result (Array Measurement) := do
  let base ← (← Provider.fromSpec spec temperature options).retry {}
  let mut measurements : Array Measurement := #[]

  -- Sequential: one request at a time — single-stream decode throughput.
  let start ← now
  let mut responses : Array Response := #[]
  for _ in [0:count] do
    responses := responses.push (← (← base.sample prompt).next)
  measurements := measurements.push (.of spec "sequential" responses ((← now) - start))

  -- Concurrent: all requests in flight at once (optionally bounded) — aggregate throughput.
  match concurrent? with
  | none => pure ()
  | some limit? =>
    let batched ← base.batch (.concurrent limit?)
    let start ← now
    let batch ← (← batched.sample prompt).nextN count
    measurements := measurements.push (.of spec "concurrent" batch ((← now) - start))
  pure measurements

private def reportLine (m : Measurement) : String :=
  let note := if m.approximate then "  (tokens approximated)" else ""
  s!"{padRight m.phase 12}{padLeft (toString m.requests) 4} req  " ++
  s!"{padLeft (toString m.tokens) 7} tok  {padLeft (toString m.ms) 7} ms  " ++
  s!"{padLeft (toString m.rate) 6} tok/s{note}"

/-- The comparison table, fastest first, so several models can be read against each other. -/
private def summary (measurements : Array Measurement) : Array String := Id.run do
  let width := measurements.foldl (fun w m => max w m.spec.length) 5
  let sorted := measurements.qsort fun a b => a.rate > b.rate
  let header := s!"{padRight "model" width}  {padRight "phase" 12}{padLeft "tok/s" 8}" ++
    s!"{padLeft "tok" 9}{padLeft "ms" 9}{padLeft "req" 6}"
  let mut lines := #["", header, "".pushn '-' header.length]
  for m in sorted do
    lines := lines.push <|
      s!"{padRight m.spec width}  {padRight m.phase 12}{padLeft (toString m.rate) 8}" ++
      s!"{padLeft (toString m.tokens) 9}{padLeft (toString m.ms) 9}{padLeft (toString m.requests) 6}" ++
      (if m.approximate then "  *" else "")
  if measurements.any (·.approximate) then
    lines := lines.push "" |>.push "* token counts estimated from response length"
  lines

private def run (argv : List String) : Result Unit := do
  let args := Cli.parse argv
  let specs := args.all "model" |>.filter (!·.isEmpty)
  if specs.isEmpty then throw <| .configuration usage
  let count ← args.natD "count" 8
  if count == 0 then throw <| .configuration "--count must be at least 1"
  let temperature ← args.floatD "temperature" 0.7
  let options ← Provider.Options.ofArgs args
  let concurrent? : Option (Option Nat) ←
    if args.isSet "concurrent" then
      match args.getD "concurrent" "" with
      | "" => pure (some none)
      | value => match value.toNat? with
        | some limit => pure (some (some limit))
        | none => throw <| .configuration s!"--concurrent expects a whole number, got '{value}'"
    else pure none
  let prompt ← match args.get? "prompt", args.get? "prompt-file" with
    | some text, none => pure text
    | none, some file => Result.fromIO Error.storage (IO.FS.readFile file)
    | none, none => pure defaultPrompt
    | some _, some _ => throw <| .configuration "--prompt and --prompt-file are exclusive"
  let request : Request := { messages := #[.user prompt] }

  let concurrency := match concurrent? with
    | none => "off"
    | some none => "unbounded"
    | some (some limit) => toString limit
  emit s!"# count={count} temperature={showFloat temperature} concurrent={concurrency}"

  -- A model that cannot be reached is reported and skipped, so one bad spec does not lose the
  -- measurements of the others.
  let mut measurements : Array Measurement := #[]
  for spec in specs do
    emit s!"\n## {spec}"
    match ← (measureModel spec options temperature count concurrent? request).toBaseIO with
    | .ok taken =>
      for m in taken do emit (reportLine m)
      measurements := measurements ++ taken
    | .error error => emit s!"failed: {error.describe}"
  if measurements.size > 1 then (summary measurements).forM emit

def main (argv : List String) : IO UInt32 := do
  match ← (run argv).toBaseIO with
  | .ok () => pure 0
  | .error error =>
    IO.eprintln s!"error: {error.describe}"
    pure 1
