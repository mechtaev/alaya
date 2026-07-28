import Alaya.Provider.ChatCompletions

namespace Alaya.Provider.XMCP

def model (name : String) (temperature : Float)
    (canonicalModelName? : Option String := none)
    (structuredOutput := Chat.StructuredOutput.native) : Result Model :=
  ChatCompletions.modelFromEnv "XMCP" "XMCP_API_KEY" "https://llm.xmcp.ltd" name temperature
    (canonicalModelName? := canonicalModelName?) (structuredOutput := structuredOutput)

end Alaya.Provider.XMCP
