import Alaya

private def run : Alaya.Result (Array String) := do
  let model ← Alaya.Provider.Yunwu.model "gpt-5.6-luna" 1.0
  let model ← model.retry {}
  let model ← model.batch .concurrent
  let model ← Alaya.Cache.persistent model { directory := ".alaya/cache" }
  let responses ← model.completeN {
    messages := #[.user "Choose an integer from 1 to 1000000. Reply with only the integer."]
  } 4
  responses.mapM fun response =>
    match response.content? with
    | some content => pure content
    | none => throw <| .protocol "Yunwu response has no message content"

def main : IO Unit := do
  let contents ← run.toIO fun error => IO.userError s!"{repr error}"
  for content in contents do
    IO.println content
