import Alaya

open Alaya
open Alaya.Chat (JsonSchema)

private def snippetSchema : JsonSchema := .object #[
  ("name", .string (description? := some "A concise, descriptive name for the function")),
  ("language", .string (description? := some "The implementation language, e.g. \"Python\"")),
  ("code", .string (description? := some "The complete, runnable function implementation")),
  ("documentation", .string (description? := some "A docstring covering the parameters and return value"))
]

private structure Snippet where
  name : String
  language : String
  code : String
  documentation : String
  deriving Lean.FromJson

private def parseSnippet (response : Chat.Response) : Result Snippet := do
  let json ← response.structured snippetSchema
  Result.fromExcept Error.protocol <| Lean.fromJson? json

private def run : Result (Array Snippet) := do
  let model ← Provider.Yunwu.model "gpt-5.6-luna" 0.2
  let model ← model.retry { retryStructuredOutput := true }
  let model ← model.batch .concurrent
  let model ← Cache.persistent model { directory := ".alaya/cache" }
  let responses ← (← model.sample {
    messages := #[.user "Write a well-documented function that merges two sorted lists into one sorted list."]
    responseFormat := .jsonSchema "documented_function" snippetSchema
  }).nextN 2
  responses.mapM parseSnippet

def main : IO Unit := do
  let snippets ← run.toIO fun error => IO.userError s!"{repr error}"
  for snippet in snippets do
    IO.println s!"# {snippet.name} ({snippet.language})"
    IO.println ""
    IO.println snippet.documentation
    IO.println ""
    IO.println snippet.code
    IO.println ""
