import Alaya.Provider.ChatCompletions

namespace Alaya.Provider.CloseAI

def model (name : String) (temperature : Float)
    (canonicalModelName? : Option String := none)
    (structuredOutput := Chat.StructuredOutput.native) : Result Model := do
  let apiKey ← Result.fromIO Error.configuration <| do
    match (← IO.getEnv "CLOSEAI_API_KEY").filter (!·.isEmpty) with
    | some key => pure key
    | none => throw <| IO.userError "CLOSEAI_API_KEY is not set"
  ChatCompletions.model {
    provider := "CloseAI", baseUrl := "https://api.openai-proxy.org/v1", apiKey, name,
    canonicalModelName?, temperature, structuredOutput
  }

end Alaya.Provider.CloseAI
