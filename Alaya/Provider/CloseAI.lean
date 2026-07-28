import Alaya.Provider.ChatCompletions

namespace Alaya.Provider.CloseAI

def model (name : String) (temperature : Float)
    (canonicalModelName? : Option String := none)
    (structuredOutput := Chat.StructuredOutput.native) : Result Model :=
  ChatCompletions.modelFromEnv "CloseAI" "CLOSEAI_API_KEY" "https://api.openai-proxy.org/v1"
    name temperature
    (canonicalModelName? := canonicalModelName?) (structuredOutput := structuredOutput)

end Alaya.Provider.CloseAI
