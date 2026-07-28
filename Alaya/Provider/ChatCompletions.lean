import Alaya.Model

namespace Alaya.Provider.ChatCompletions

structure Config where
  provider : String
  baseUrl : String
  apiKey : String
  name : String
  canonicalModelName? : Option String := none
  temperature : Float
  structuredOutput : Chat.StructuredOutput := .native
  nativeBatching : Bool := true
  /-- Abort the whole request after this many milliseconds so a stalled provider cannot hang. -/
  requestTimeoutMs : Nat := 600000
  /-- Abort connection establishment after this many milliseconds. -/
  connectTimeoutMs : Nat := 30000

private def validateResponses (config : Config) (request : Chat.Request)
    (responses : Array Chat.Response) : Result (Array Chat.Response) :=
  responses.mapM fun response => do
    let response := { response with structuredOutput := config.structuredOutput }
    match request.responseFormat with
    | .text => pure response
    | .jsonSchema _ schema =>
      let _ ← response.structured schema
      pure response

private structure CurlResponse where
  exitCode : UInt32
  statusOutput : String
  stderr : String
  body : String
  headers : String

/-- Formats a millisecond duration as the decimal seconds string curl expects for its timeouts. -/
private def secondsArg (ms : Nat) : String :=
  let whole := ms / 1000
  let frac := ms % 1000
  let fracStr :=
    if frac < 10 then s!"00{frac}"
    else if frac < 100 then s!"0{frac}"
    else toString frac
  s!"{whole}.{fracStr}"

private def curlConfig (apiKey : String) : String :=
  let escape (value : String) := (value.replace "\\" "\\\\").replace "\"" "\\\""
  s!"header = \"Content-Type: application/json\"\nheader = \"Authorization: Bearer {escape apiKey}\"\n"

private def requestIO (config : Config) (payload : String) : IO CurlResponse :=
  IO.FS.withTempDir fun directory => do
    let configPath := directory / "curl.conf"
    let payloadPath := directory / "request.json"
    let bodyPath := directory / "response.json"
    let headersPath := directory / "response.headers"
    IO.FS.writeFile configPath <| curlConfig config.apiKey
    IO.FS.writeFile payloadPath payload
    let result ← IO.Process.output {
      cmd := "curl"
      args := #[
        "--silent", "--show-error", "--config", configPath.toString,
        "--connect-timeout", secondsArg config.connectTimeoutMs,
        "--max-time", secondsArg config.requestTimeoutMs,
        "--request", "POST", "--data", s!"@{payloadPath}",
        "--output", bodyPath.toString, "--dump-header", headersPath.toString,
        "--write-out", "%{http_code}", s!"{config.baseUrl}/chat/completions"
      ]
    }
    let body ← if ← bodyPath.pathExists then IO.FS.readFile bodyPath else pure ""
    let headers ← if ← headersPath.pathExists then IO.FS.readFile headersPath else pure ""
    pure { exitCode := result.exitCode, statusOutput := result.stdout, stderr := result.stderr, body, headers }

/-- Extracts a provider throttling delay: `retry-after-ms` (milliseconds, used by some
providers, preferred as the more precise) or the integer-seconds form of `retry-after`. -/
private def retryAfterMs? (headers : String) : Option Nat :=
  -- The dump can hold several responses (redirects); reversing makes the final response win.
  -- Lowercasing leaves the digits intact, so values can be parsed from the normalized lines.
  let lines := (headers.splitOn "\n").reverse.map fun line => line.trimAscii.toString.toLower
  let value? (name : String) : Option Nat :=
    lines.findSome? fun line =>
      if line.startsWith s!"{name}:" then
        line.drop (name.length + 1) |>.trimAscii.toString.toNat?
      else none
  (value? "retry-after-ms").orElse fun _ => (value? "retry-after").map (· * 1000)

private def complete (config : Config) (temperature : Lean.Json) (request : Chat.Request)
    (n : Nat) : Result (Array Chat.Response) := do
  let payload := request.toJson config.structuredOutput
    |>.setObjVal! "model" config.name
    |>.setObjVal! "temperature" temperature
  -- Omit `n` for single completions so providers without multi-sample support stay compatible.
  let payload := if n == 1 then payload else payload.setObjVal! "n" n
  let result ← Result.fromIO Error.transport <| requestIO config payload.compress
  -- curl exit code 28 is a connect or total-request timeout; treat delivery as unknown.
  if result.exitCode == 28 then
    throw <| .transport s!"{config.provider} request timed out after {secondsArg config.requestTimeoutMs}s"
  if result.exitCode != 0 then
    throw <| .transport s!"{config.provider} request failed: {result.stderr}\n{result.body}"
  let status ← match result.statusOutput.trimAscii.toString.toNat? with
    | some status => pure status
    | none => throw <| .transport s!"{config.provider} returned no HTTP status"
  if status < 200 || status >= 300 then throw <| .http status result.body (retryAfterMs? result.headers)
  let raw ← Result.fromExcept Error.protocol <| Lean.Json.parse result.body
  let responses ← Chat.Response.fromJsons raw
  validateResponses config request responses

/-- Creates a one-response transport model for an OpenAI-compatible chat-completions API. -/
def model (config : Config) : Result Model := do
  let temperature ← match Lean.JsonNumber.fromFloat? config.temperature with
    | .inr number => pure <| Lean.Json.num number
    | .inl _ => throw <| .configuration "temperature must be finite"
  pure {
    identity := Lean.Json.mkObj [
      ("model", config.canonicalModelName?.getD config.name),
      ("temperature", temperature)
    ]
    structuredOutput := config.structuredOutput
    sample := fun request => pure {
      next := do
        let responses ← complete config temperature request 1
        match responses[0]? with
        | some response => pure response
        | none => throw <| .protocol "provider returned no responses"
      nextN? := if config.nativeBatching then some (complete config temperature request) else none
    }
  }

/-- Builds a provider model whose API key (and optionally base URL) come from the environment.

The key is read from `keyVar`, treating empty values as unset. `defaultKey?` supplies a
fallback for servers that need no real credential; without one, a missing key is a
configuration error. When `baseUrlVar?` is given and set, it overrides `baseUrl`. -/
def modelFromEnv (provider keyVar baseUrl name : String) (temperature : Float)
    (defaultKey? : Option String := none)
    (baseUrlVar? : Option String := none)
    (canonicalModelName? : Option String := none)
    (structuredOutput := Chat.StructuredOutput.native) : Result Model := do
  let env (envVar : String) : Result (Option String) :=
    Result.fromIO Error.configuration do pure ((← IO.getEnv envVar).filter (!·.isEmpty))
  let apiKey ← match (← env keyVar), defaultKey? with
    | some key, _ => pure key
    | none, some fallback => pure fallback
    | none, none => throw <| .configuration s!"{keyVar} is not set"
  let baseUrl ← match baseUrlVar? with
    | some envVar => pure ((← env envVar).getD baseUrl)
    | none => pure baseUrl
  model { provider, baseUrl, apiKey, name, canonicalModelName?, temperature, structuredOutput }

end Alaya.Provider.ChatCompletions
