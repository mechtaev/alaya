import Alaya.Chat.Schema

namespace Alaya.Chat

structure ToolCall where
  id : String
  name : String
  arguments : Lean.Json
  deriving Inhabited

inductive Message where
  | system (content : String)
  | user (content : String)
  | assistant (content? : Option String := none) (toolCalls : Array ToolCall := #[])
  | tool (callId : String) (content : Lean.Json)
  deriving Inhabited

namespace Message

private def toolCallToJson (call : ToolCall) : Lean.Json :=
  .mkObj [
    ("id", call.id),
    ("type", "function"),
    ("function", .mkObj [
      ("name", call.name),
      ("arguments", call.arguments.compress)
    ])
  ]

def toJson : Message -> Lean.Json
  | .system content => .mkObj [("role", "system"), ("content", content)]
  | .user content => .mkObj [("role", "user"), ("content", content)]
  | .assistant content? toolCalls =>
    let json := Lean.Json.mkObj [("role", "assistant")]
    let json := match content? with | some content => json.setObjVal! "content" content | none => json
    if toolCalls.isEmpty then json else json.setObjVal! "tool_calls" (.arr <| toolCalls.map toolCallToJson)
  | .tool callId content =>
    .mkObj [("role", "tool"), ("tool_call_id", callId), ("content", content.compress)]

end Message

structure ToolDefinition where
  name : String
  description : String
  parameters : JsonSchema
  deriving Inhabited

namespace ToolDefinition

def toJson (tool : ToolDefinition) : Lean.Json :=
  .mkObj [
    ("type", "function"),
    ("function", .mkObj [
      ("name", tool.name),
      ("description", tool.description),
      ("parameters", tool.parameters.toJson)
    ])
  ]

end ToolDefinition

inductive ToolChoice where
  | auto
  | none
  | required
  | function (name : String)
  deriving Repr, Inhabited

namespace ToolChoice

def toJson : ToolChoice -> Lean.Json
  | .auto => "auto"
  | .none => "none"
  | .required => "required"
  | .function name => .mkObj [("type", "function"), ("function", .mkObj [("name", name)])]

end ToolChoice

inductive StructuredOutput where
  | native
  | markdownCodeFence
  deriving Repr, Inhabited

namespace StructuredOutput

def toJson : StructuredOutput -> Lean.Json
  | .native => "native"
  | .markdownCodeFence => "markdown_code_fence"

end StructuredOutput

inductive ResponseFormat
  | text
  | jsonSchema (name : String) (schema : JsonSchema)
  deriving Repr, Inhabited

namespace ResponseFormat

def toJson : ResponseFormat -> Lean.Json
  | .text => .mkObj [("type", "text")]
  | .jsonSchema name schema => JsonSchema.responseFormat name schema

end ResponseFormat

/-- The provider-independent input to an OpenAI-compatible completion. -/
structure Request where
  messages : Array Message
  tools : Array ToolDefinition := #[]
  toolChoice : ToolChoice := .auto
  responseFormat : ResponseFormat := .text
  deriving Inhabited

namespace Request

private def fallbackInstruction (schema : JsonSchema) : String :=
  "\n\nReturn only JSON matching this schema, wrapped in a ```json code fence:\n" ++ schema.toJson.pretty

private def addFallbackInstruction (messages : Array Message) (schema : JsonSchema) : Array Message :=
  let rec addToLastUser : List Message -> List Message
    | [] => [.user <| fallbackInstruction schema]
    | .user content :: rest => .user (content ++ fallbackInstruction schema) :: rest
    | message :: rest => message :: addToLastUser rest
  (addToLastUser messages.toList.reverse).reverse.toArray

def toJson (request : Request) (structuredOutput := StructuredOutput.native) : Lean.Json :=
  let messages := match structuredOutput, request.responseFormat with
    | .markdownCodeFence, .jsonSchema _ schema => addFallbackInstruction request.messages schema
    | _, _ => request.messages
  let responseFormat := match structuredOutput with
    | .native => request.responseFormat
    | .markdownCodeFence => .text
  let json := Lean.Json.mkObj [
    ("messages", .arr <| messages.map Message.toJson),
    ("response_format", responseFormat.toJson)
  ]
  if request.tools.isEmpty then json else
    json.setObjVal! "tools" (.arr <| request.tools.map ToolDefinition.toJson)
      |>.setObjVal! "tool_choice" request.toolChoice.toJson

end Request

/-- Provider-reported token counts. Fields are optional because providers differ in what they report. -/
structure TokenUsage where
  input? : Option Nat := none
  output? : Option Nat := none
  total? : Option Nat := none
  deriving Repr, Inhabited

/-- A parsed OpenAI-compatible assistant response, retaining the original provider payload. -/
structure Response where
  content? : Option String := none
  toolCalls : Array ToolCall := #[]
  usage? : Option TokenUsage := none
  raw : Lean.Json
  structuredOutput : StructuredOutput := .native
  deriving Inhabited

namespace Response

private def liftJson (error : String) (result : Except String α) : Except String α :=
  result.mapError fun _ => error

private def parseToolCall (json : Lean.Json) : Except String ToolCall := do
  let id ← liftJson "tool call has no id" <| json.getObjVal? "id" >>= Lean.Json.getStr?
  let function ← liftJson "tool call has no function" <| json.getObjVal? "function"
  let name ← liftJson "tool call function has no name" <| function.getObjVal? "name" >>= Lean.Json.getStr?
  let arguments ← liftJson "tool call function has invalid arguments" <|
    function.getObjVal? "arguments" >>= Lean.Json.getStr? >>= Lean.Json.parse
  pure { id, name, arguments }

private def usageFromJson? (raw : Lean.Json) : Option TokenUsage :=
  match raw.getObjVal? "usage" with
  | .ok usage =>
    let input? := (usage.getObjVal? "prompt_tokens" >>= Lean.Json.getNat?).toOption.orElse fun _ =>
      (usage.getObjVal? "input_tokens" >>= Lean.Json.getNat?).toOption
    let output? := (usage.getObjVal? "completion_tokens" >>= Lean.Json.getNat?).toOption.orElse fun _ =>
      (usage.getObjVal? "output_tokens" >>= Lean.Json.getNat?).toOption
    let total? := (usage.getObjVal? "total_tokens" >>= Lean.Json.getNat?).toOption
    some { input?, output?, total? }
  | .error _ => none

private def fencedJson (content : String) : Except String String :=
  match content.splitOn "```" with
  | _ :: fenced :: _ =>
    let body := if fenced.startsWith "json\n" then fenced.drop 5 else fenced
    pure body.trimAscii.toString
  | _ => throw "response content has no markdown code fence"

/-- Parses and validates a structured assistant response against `schema`. -/
def structured (response : Response) (schema : JsonSchema) : Except String Lean.Json := do
  let content ←
    match response.content? with
    | some content => pure content
    | none => throw "response has no message content"
  let content ← match response.structuredOutput with
    | .native => pure content
    | .markdownCodeFence => fencedJson content
  let json ← liftJson "response content is not valid JSON" <| Lean.Json.parse content
  schema.validate json
  pure json

def fromJsons (raw : Lean.Json) : Except String (Array Response) := do
  let choices ← liftJson "response has no choices" <| raw.getObjVal? "choices" >>= Lean.Json.getArr?
  let usage? := usageFromJson? raw
  choices.mapM fun choice => do
    let message ← liftJson "response choice has no message" <| choice.getObjVal? "message"
    let content? := (message.getObjVal? "content" >>= Lean.Json.getStr?).toOption
    let toolCalls ← match message.getObjVal? "tool_calls" with
      | .ok calls => calls.getArr?.bind fun calls => calls.mapM parseToolCall
      | .error _ => pure #[]
    pure { content?, toolCalls, usage?, raw }

def fromJson (raw : Lean.Json) : Except String Response := do
  let responses ← fromJsons raw
  match responses[0]? with
  | some response => pure response
  | none => throw "response has no choices"

end Response
end Alaya.Chat
