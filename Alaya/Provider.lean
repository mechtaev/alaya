import Alaya.Cli
import Alaya.Provider.ChatCompletions
import Alaya.Provider.CloseAI
import Alaya.Provider.XMCP
import Alaya.Provider.Yunwu
import Alaya.Provider.Dgx

/-!
The provider table: one place that turns a `PROVIDER:NAME` spec from a command line into a bare
provider model, so every executable understands the same set of providers and the same flags.
-/

namespace Alaya.Provider

/-- The providers a spec may name. -/
def names : Array String := #["yunwu", "closeai", "xmcp", "dgx"]

/-- Settings that only some providers accept, gathered from the command line. -/
structure Options where
  /-- Endpoint for `dgx`; `none` keeps the built-in address and honours `DGX_BASE_URL`. -/
  dgxEndpoint? : Option Dgx.Endpoint := none
  deriving Repr, Inhabited

/-- Reads `--url` and `--port`, which address the DGX Spark. `--port` alone changes the port of
the default host; given both, `--port` wins over any port inside `--url`. -/
def Options.ofArgs (args : Cli.Args) : Result Options := do
  let fromUrl ← match args.get? "url" with
    | none => pure none
    | some url => match Dgx.Endpoint.ofUrl url with
      | .ok endpoint => pure (some endpoint)
      | .error message => throw <| .configuration s!"--url: {message}"
  let dgxEndpoint? ← match ← args.nat? "port" with
    | none => pure fromUrl
    | some port => pure (some { fromUrl.getD {} with port })
  pure { dgxEndpoint? }

/-- Splits a `PROVIDER:NAME` spec. The model name may itself contain colons. -/
def splitSpec (spec : String) : String × String :=
  match spec.splitOn ":" with
  | provider :: rest => (provider, ":".intercalate rest)
  | [] => (spec, "")

/-- Resolves a `PROVIDER:NAME` spec into a bare provider model — no retry, batching, or cache. -/
def fromSpec (spec : String) (temperature : Float) (options : Options := {}) : Result Model :=
  let (provider, name) := splitSpec spec
  if name.isEmpty then
    throw <| .configuration s!"'{spec}' is not a PROVIDER:NAME spec (e.g. dgx:gpt-oss-120b)"
  else match provider with
    | "yunwu" => Yunwu.model name temperature
    | "closeai" => CloseAI.model name temperature
    | "xmcp" => XMCP.model name temperature
    | "dgx" => Dgx.model name temperature options.dgxEndpoint?
    | other =>
      throw <| .configuration s!"unknown provider: {other} (use {"|".intercalate names.toList})"

end Alaya.Provider
