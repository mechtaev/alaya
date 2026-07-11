import Alaya.Provider.ChatCompletions

namespace Alaya.Provider.XMCP

def model (name : String) (temperature : Float)
    (canonicalModelName? : Option String := none)
    (structuredOutput := Chat.StructuredOutput.native) : Result Model := do
  let apiKey ← Result.fromIO Error.configuration <| do
    match (← IO.getEnv "XMCP_API_KEY").filter (!·.isEmpty) with
    | some key => pure key
    | none => throw <| IO.userError "XMCP_API_KEY is not set"
  ChatCompletions.model {
    provider := "XMCP", baseUrl := "https://llm.xmcp.ltd", apiKey, name,
    canonicalModelName?, temperature, structuredOutput
  }

end Alaya.Provider.XMCP
