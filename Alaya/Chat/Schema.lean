import Lean.Data.Json

namespace Alaya.Chat

/-- A JSON value permitted in a JSON Schema `enum`. -/
inductive EnumValue where
  | null
  | boolean (value : Bool)
  | integer (value : Int)
  | number (value : Float)
  | string (value : String)
  deriving Repr, Inhabited

namespace EnumValue

protected def toJson : EnumValue -> Lean.Json
  | .null => .null
  | .boolean value => value
  | .integer value => value
  | .number value =>
    match Lean.JsonNumber.fromFloat? value with
    | .inr jsonNumber => .num jsonNumber
    | .inl _ => .null
  | .string value => value

end EnumValue

/-- A strict-mode, OpenAI-compatible JSON Schema.

Object properties are always required and objects always reject unspecified properties.
Use `anyOf #[schema, .null]` for nullable properties. -/
inductive JsonSchema where
  | null (description? : Option String := none)
  | boolean (description? : Option String := none)
  | integer (description? : Option String := none) (enum : Array Int := #[])
  | number (description? : Option String := none) (enum : Array Float := #[])
  | string (description? : Option String := none) (enum : Array String := #[])
  | array (items : JsonSchema) (description? : Option String := none)
  | object (properties : Array (String × JsonSchema)) (description? : Option String := none)
  | anyOf (alternatives : Array JsonSchema) (description? : Option String := none)
  deriving Repr, Inhabited

namespace JsonSchema

private def withDescription (schema : Lean.Json) (description? : Option String) : Lean.Json :=
  match description? with
  | some description => schema.setObjVal! "description" description
  | none => schema

private def enumValues (values : Array EnumValue) : List (String × Lean.Json) :=
  if values.isEmpty then [] else [("enum", Lean.Json.arr <| values.map EnumValue.toJson)]

private def describePath (path : String) (message : String) : String :=
  if path.isEmpty then message else s!"{path}: {message}"

private def validateEnum (path : String) (values : Array α) (value : α) [BEq α] : Except String Unit :=
  if values.isEmpty || values.contains value then
    pure ()
  else
    throw <| describePath path "value is not in the enum"

/-- Validates a JSON value against this strict OpenAI-compatible schema.

Descriptions are documentation only and do not affect validation. -/
partial def validate (schema : JsonSchema) (value : Lean.Json) (path := "") : Except String Unit :=
  match schema with
  | .null _ =>
    if value.isNull then pure () else throw <| describePath path "expected null"
  | .boolean _ => do
    let actual ← value.getBool?.mapError (fun _ => describePath path "expected a boolean")
    pure ()
  | .integer _ enum => do
    let actual ← value.getInt?.mapError (fun _ => describePath path "expected an integer")
    validateEnum path enum actual
  | .number _ enum => do
    let actual ← value.getNum?.mapError (fun _ => describePath path "expected a number")
    let actual := actual.toFloat
    validateEnum path enum actual
  | .string _ enum => do
    let actual ← value.getStr?.mapError (fun _ => describePath path "expected a string")
    validateEnum path enum actual
  | .array items _ => do
    let values ← value.getArr?.mapError (fun _ => describePath path "expected an array")
    for h : index in [0:values.size] do
      validate items values[index] s!"{path}[{index}]"
  | .object properties _ => do
    let object ← value.getObj?.mapError (fun _ => describePath path "expected an object")
    for (name, propertySchema) in properties do
      let property ←
        match object.get? name with
        | some property => pure property
        | none => throw <| describePath path s!"missing required property `{name}`"
      validate propertySchema property (if path.isEmpty then name else s!"{path}.{name}")
    let validNames := properties.map Prod.fst
    if object.all (fun name _ => validNames.contains name) then
      pure ()
    else
      throw <| describePath path "contains an unspecified property"
  | .anyOf alternatives _ =>
    if alternatives.any fun alternative => (validate alternative value path).isOk then
      pure ()
    else
      throw <| describePath path "does not match any alternative"

/-- Serializes this schema to the JSON Schema subset accepted by OpenAI-compatible strict mode. -/
partial def toJson : JsonSchema -> Lean.Json
  | .null description? =>
    withDescription (.mkObj [("type", "null")]) description?
  | .boolean description? =>
    withDescription (.mkObj [("type", "boolean")]) description?
  | .integer description? enum =>
    withDescription (.mkObj <| [("type", ("integer" : Lean.Json))] ++ enumValues (enum.map .integer)) description?
  | .number description? enum =>
    withDescription (.mkObj <| [("type", ("number" : Lean.Json))] ++ enumValues (enum.map .number)) description?
  | .string description? enum =>
    withDescription (.mkObj <| [("type", ("string" : Lean.Json))] ++ enumValues (enum.map .string)) description?
  | .array items description? =>
    withDescription (.mkObj [("type", "array"), ("items", items.toJson)]) description?
  | .object properties description? =>
    let fields := properties.map fun (name, schema) => (name, schema.toJson)
    let required := properties.map fun (name, _) => Lean.Json.str name
    withDescription (.mkObj [
      ("type", "object"),
      ("properties", .mkObj fields.toList),
      ("required", .arr required),
      ("additionalProperties", false)
    ]) description?
  | .anyOf alternatives description? =>
    withDescription (.mkObj [("anyOf", .arr <| alternatives.map toJson)]) description?

/-- Builds the `response_format` value for an OpenAI-compatible chat-completions request. -/
def responseFormat (name : String) (schema : JsonSchema) : Lean.Json :=
  .mkObj [
    ("type", "json_schema"),
    ("json_schema", .mkObj [
      ("name", name),
      ("strict", true),
      ("schema", schema.toJson)
    ])
  ]

end JsonSchema
end Alaya.Chat
