import Alaya.Provider.ChatCompletions

namespace Alaya.Provider.Yunwu

def model (name : String) (temperature : Float)
    (canonicalModelName? : Option String := none)
    (structuredOutput := Chat.StructuredOutput.native) : Result Model :=
  ChatCompletions.modelFromEnv "Yunwu" "YUNWU_API_KEY" "https://yunwu.ai/v1" name temperature
    (canonicalModelName? := canonicalModelName?) (structuredOutput := structuredOutput)

end Alaya.Provider.Yunwu
