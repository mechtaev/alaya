import Std.Sync.Semaphore
import Alaya.Error
import Alaya.Chat.Protocol
import Alaya.Retry

namespace Alaya

structure Model.Stream where
  next : Result Chat.Response
  nextN? : Option (Nat -> Result (Array Chat.Response)) := none

namespace Model.Stream

def nextN (stream : Stream) (n : Nat) : Result (Array Chat.Response) :=
  match stream.nextN? with
  | some nextN => nextN n
  | none => do
    let mut responses := #[]
    for _ in List.range n do responses := responses.push (← stream.next)
    pure responses

end Model.Stream

inductive BatchSampling where
  | native
  /-- Every request in flight at once, optionally bounded to `maxInFlight?` concurrent provider
  requests so fan-out and concurrent callers cannot saturate a provider into rate limiting
  (HTTP 429). The bound is shared by all streams of the adapted model. -/
  | concurrent (maxInFlight? : Option Nat := none)
  | sequential
  deriving Repr, Inhabited

structure Model where
  identity : Lean.Json
  structuredOutput : Chat.StructuredOutput := .native
  sample : Chat.Request -> Result Model.Stream

namespace Model

def cacheKey (model : Model) (request : Chat.Request) : String :=
  Lean.Json.mkObj [
    ("model", model.identity),
    ("structured_output", model.structuredOutput.toJson),
    ("request", request.toJson model.structuredOutput)
  ] |>.compress

/-- Retries each single response operation before a batching adapter fans it out. -/
def retry (inner : Model) (config : Retry.Config) : Result Model :=
  pure {
    identity := inner.identity
    structuredOutput := inner.structuredOutput
    sample := fun request => do
      let stream ← inner.sample request
      pure {
        next := Retry.run config stream.next
        nextN? := stream.nextN?.map fun nextN => fun n => Retry.run config (nextN n)
      }
  }

/-- Selects native, concurrent, or sequential sampling on top of retried single requests. -/
def batch (inner : Model) (mode : BatchSampling) : Result Model := do
  let semaphore? : Option Std.Semaphore ← match mode with
    | .concurrent (some 0) => throw <| .configuration "batch maxInFlight must be at least one"
    | .concurrent (some permits) => some <$> Std.Semaphore.new permits
    | _ => pure none
  pure {
    identity := inner.identity
    structuredOutput := inner.structuredOutput
    sample := fun request => do
      let stream ← inner.sample request
      let nextN (n : Nat) : Result (Array Chat.Response) :=
        match mode with
        | .native => stream.nextN n
        | .sequential => Model.Stream.nextN { next := stream.next } n
        | .concurrent _ => do
          -- Each request blocks its thread on a curl subprocess for the whole round-trip, so run it
          -- on a dedicated thread rather than a shared task-pool worker. Default-priority tasks would
          -- cap real parallelism at the pool size and let blocked workers starve the scheduler.
          let tasks ← Result.fromIO Error.transport <| (List.replicate n ()).mapM fun _ =>
            BaseIO.asTask (prio := .dedicated) do
              let sampleOnce : BaseIO (Except Error Chat.Response) := do
                match (← (inner.sample request).toBaseIO) with
                | .ok stream => stream.next.toBaseIO
                | .error error => pure <| .error error
              match semaphore? with
              | none => sampleOnce
              | some semaphore =>
                -- Block this dedicated thread until a permit frees; one permit covers one
                -- provider request for its whole round-trip. `sampleOnce` cannot throw (its
                -- failures are values), so the release always runs.
                let permit ← Std.Semaphore.acquire semaphore
                let _ ← IO.wait permit.result!
                let result ← sampleOnce
                Std.Semaphore.release semaphore
                pure result
          let results ← Result.fromIO Error.transport <| tasks.mapM fun task => pure task.get
          let mut responses := #[]
          for result in results do
            match result with
            | .ok response => responses := responses.push response
            | .error error => throw error
          pure responses
      let next : Result Chat.Response := do
        let responses ← nextN 1
        match responses[0]? with
        | some response => pure response
        | none => throw <| .protocol "model returned no responses"
      pure { next, nextN? := some nextN }
  }

def repeatable (inner : Model) : Result Model := do
  let entries ← Result.fromIO Error.cache <| IO.mkRef ({} : Std.HashMap String (Array Chat.Response))
  pure {
    identity := inner.identity
    structuredOutput := inner.structuredOutput
    sample := fun request => do
      let key := inner.cacheKey request
      let index ← Result.fromIO Error.cache <| IO.mkRef 0
      pure {
        next := do
          let current ← Result.fromIO Error.cache <| index.modifyGet fun index => (index, index + 1)
          let cached ← Result.fromIO Error.cache entries.get
          let responses := cached.getD key #[]
          match responses[current]? with
          | some response => pure response
          | none =>
            let stream ← inner.sample request
            let response ← stream.next
            let _ ← Result.fromIO Error.cache <| entries.modify fun entries =>
              entries.insert key ((entries.getD key #[]).push response)
            pure response
      }
  }

def independent (inner : Model) : Result Model := do
  let streams ← Result.fromIO Error.cache <| IO.mkRef ({} : Std.HashMap String Model.Stream)
  pure {
    identity := inner.identity
    structuredOutput := inner.structuredOutput
    sample := fun request => do
      let key := inner.cacheKey request
      let existing ← Result.fromIO Error.cache streams.get
      match existing.get? key with
      | some stream => pure stream
      | none =>
        let stream ← inner.sample request
        let _ ← Result.fromIO Error.cache <| streams.modify fun streams => streams.insert key stream
        pure stream
  }

end Model
end Alaya
