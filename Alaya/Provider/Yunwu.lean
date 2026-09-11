import Alaya.Provider.ChatCompletions

namespace Alaya.Provider.Yunwu

def model (name : String) (temperature : Float)
    (canonicalModelName? : Option String := none)
    (structuredOutput := Chat.StructuredOutput.native) (echoReasoning := false) : Result Model :=
  -- `YUNWU_BASE_URL` overrides the endpoint, as `DGX_BASE_URL` does for `dgx`: the service has
  -- moved hosts before (yunwu.ai answered 403 "account migrated to api.openlux.ai" in
  -- September 2026), and a run should not need a rebuild to follow it.
  ChatCompletions.modelFromEnv "Yunwu" "YUNWU_API_KEY" "https://yunwu.ai/v1" name temperature
    (baseUrlVar? := some "YUNWU_BASE_URL")
    (canonicalModelName? := canonicalModelName?) (structuredOutput := structuredOutput)
    (echoReasoning := echoReasoning)

end Alaya.Provider.Yunwu
