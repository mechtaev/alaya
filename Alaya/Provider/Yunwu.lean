import Alaya.Provider.ChatCompletions

namespace Alaya.Provider.Yunwu

def model (name : String) (temperature : Float)
    (canonicalModelName? : Option String := none)
    (structuredOutput := Chat.StructuredOutput.native) (echoReasoning := false) : Result Model :=
  ChatCompletions.modelFromEnv "Yunwu" "YUNWU_API_KEY" "https://yunwu.ai/v1" name temperature
    (baseUrlVar? := some "YUNWU_BASE_URL")
    (canonicalModelName? := canonicalModelName?) (structuredOutput := structuredOutput)
    (echoReasoning := echoReasoning)

end Alaya.Provider.Yunwu
