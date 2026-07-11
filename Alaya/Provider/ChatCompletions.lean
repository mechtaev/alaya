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

private def validateResponses (config : Config) (request : Chat.Request)
    (responses : Array Chat.Response) : Result (Array Chat.Response) :=
  responses.mapM fun response => do
    let response := { response with structuredOutput := config.structuredOutput }
    match request.responseFormat with
    | .text => pure response
    | .jsonSchema _ schema =>
      let _ ← Result.fromExcept Error.structuredOutput <| response.structured schema
      pure response

private structure CurlResponse where
  exitCode : UInt32
  statusOutput : String
  stderr : String
  body : String
  headers : String

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
        "--request", "POST", "--data", s!"@{payloadPath}",
        "--output", bodyPath.toString, "--dump-header", headersPath.toString,
        "--write-out", "%{http_code}", s!"{config.baseUrl}/chat/completions"
      ]
    }
    let body ← if ← bodyPath.pathExists then IO.FS.readFile bodyPath else pure ""
    let headers ← if ← headersPath.pathExists then IO.FS.readFile headersPath else pure ""
    pure { exitCode := result.exitCode, statusOutput := result.stdout, stderr := result.stderr, body, headers }

private def retryAfterMs? (headers : String) : Option Nat :=
  (headers.splitOn "\n").reverse.findSome? fun line =>
    let line := line.trimAscii.toString
    if line.toLower.startsWith "retry-after:" then
      line.drop "retry-after:".length |>.trimAscii.toString.toNat?.map (· * 1000)
    else none

private def complete (config : Config) (temperature : Lean.Json) (request : Chat.Request)
    (n : Nat) : Result (Array Chat.Response) := do
  let payload := request.toJson config.structuredOutput
    |>.setObjVal! "model" config.name
    |>.setObjVal! "temperature" temperature
    |>.setObjVal! "n" n
  let result ← Result.fromIO Error.transport <| requestIO config payload.compress
  let status ← match result.statusOutput.trimAscii.toString.toNat? with
    | some status => pure status
    | none => throw <| .transport s!"{config.provider} returned no HTTP status"
  if result.exitCode != 0 then
    throw <| .transport s!"{config.provider} request failed: {result.stderr}\n{result.body}"
  if status < 200 || status >= 300 then throw <| .http status result.body (retryAfterMs? result.headers)
  let raw ← Result.fromExcept Error.protocol <| Lean.Json.parse result.body
  let responses ← Result.fromExcept Error.protocol <| Chat.Response.fromJsons raw
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

end Alaya.Provider.ChatCompletions
