import Alaya.Provider.ChatCompletions

namespace Alaya.Provider.Dgx

/-- Where a DGX Spark's OpenAI-compatible server (e.g. vLLM) listens. The defaults are the
Spark's own address over the direct network link and vLLM's default port. -/
structure Endpoint where
  scheme : String := "http"
  host : String := "10.42.0.1"
  port : Nat := 8000
  /-- Path prefix the OpenAI-compatible routes live under. -/
  path : String := "/v1"
  deriving Repr, Inhabited, BEq

def Endpoint.baseUrl (endpoint : Endpoint) : String :=
  s!"{endpoint.scheme}://{endpoint.host}:{endpoint.port}{endpoint.path}"

/-- Reads an endpoint given as a URL, layering whatever it specifies onto the defaults. All of
`http://host:9000/v1`, `host:9000`, and `host` are accepted; a missing scheme is `http`, a
missing port is `8000`, and a missing path is `/v1`. -/
def Endpoint.ofUrl (url : String) : Except String Endpoint := do
  let trimmed := url.trimAscii.toString
  if trimmed.isEmpty then throw "empty URL"
  let (scheme, rest) := match trimmed.splitOn "://" with
    | [only] => ("http", only)
    | scheme :: more => (scheme, "://".intercalate more)
    | [] => ("http", "")
  let (authority, path) := match rest.splitOn "/" with
    | [only] => (only, "/v1")
    | first :: more => (first, "/" ++ "/".intercalate more)
    | [] => ("", "/v1")
  let stripped := (path.dropEndWhile (· == '/')).toString
  let path := if stripped.isEmpty then "/v1" else stripped
  match authority.splitOn ":" with
  | [host] =>
    if host.isEmpty then throw s!"no host in '{url}'"
    pure { scheme, host, path }
  | [host, port] =>
    if host.isEmpty then throw s!"no host in '{url}'"
    match port.toNat? with
    | some port => pure { scheme, host, port, path }
    | none => throw s!"'{port}' is not a port number"
  | _ => throw s!"cannot read '{url}' as [scheme://]host[:port][/path]"

/-- An OpenAI-compatible model served by a DGX Spark.

`endpoint?` pins the address explicitly — that is what `--url` and `--port` set. Left `none`,
the address is `http://10.42.0.1:8000/v1`, overridable with `DGX_BASE_URL`. Local servers
usually need no credential, so `DGX_API_KEY` defaults to `EMPTY` (the vLLM convention). -/
def model (name : String) (temperature : Float)
    (endpoint? : Option Endpoint := none)
    (canonicalModelName? : Option String := none)
    (structuredOutput := Chat.StructuredOutput.native) : Result Model :=
  ChatCompletions.modelFromEnv "DGX" "DGX_API_KEY"
    ((endpoint?.getD {}).baseUrl) name temperature
    (defaultKey? := some "EMPTY")
    (baseUrlVar? := if endpoint?.isSome then none else some "DGX_BASE_URL")
    (canonicalModelName? := canonicalModelName?) (structuredOutput := structuredOutput)

end Alaya.Provider.Dgx
