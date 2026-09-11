import Alaya.Provider.ChatCompletions

namespace Alaya.Provider.XMCP

def model (name : String) (temperature : Float)
    (canonicalModelName? : Option String := none)
    (structuredOutput := Chat.StructuredOutput.native) (echoReasoning := false) : Result Model :=
  ChatCompletions.modelFromEnv "XMCP" "XMCP_API_KEY" "https://llm.xmcp.ltd" name temperature
    (canonicalModelName? := canonicalModelName?) (structuredOutput := structuredOutput)
    (echoReasoning := echoReasoning)

end Alaya.Provider.XMCP
