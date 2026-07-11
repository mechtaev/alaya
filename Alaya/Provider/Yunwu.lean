import Alaya.Provider.ChatCompletions

namespace Alaya.Provider.Yunwu

def model (name : String) (temperature : Float)
    (canonicalModelName? : Option String := none)
    (structuredOutput := Chat.StructuredOutput.native) : Result Model := do
  let apiKey ← Result.fromIO Error.configuration <| do
    match (← IO.getEnv "YUNWU_API_KEY").filter (!·.isEmpty) with
    | some key => pure key
    | none => throw <| IO.userError "YUNWU_API_KEY is not set"
  ChatCompletions.model {
    provider := "Yunwu", baseUrl := "https://yunwu.ai/v1", apiKey, name,
    canonicalModelName?
    temperature
    structuredOutput
  }

end Alaya.Provider.Yunwu
