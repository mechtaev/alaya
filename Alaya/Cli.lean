import Lean.Data.Json
import Alaya.Error

/-!
Command-line parsing shared by the `alaya` and `benchmark` executables.

A command line is a sequence of positionals and `--flag value` pairs, freely interleaved, plus
optional short aliases (`alaya` maps `-m` to `--note`). Flags are kept as an array of
occurrences rather than a map, so a flag may be repeated and every value survives — that is what
lets `benchmark` take several `--model` specs in one run.

A `--flag` that is last on the line, or followed by another `--flag`, is a *switch*: it is
recorded with an empty value, so `--concurrent` and `--concurrent 4` are both accepted. The
price of that rule is that a flag value may not itself begin with `--`.
-/

namespace Alaya.Cli

/-- A parsed command line: positionals in order, and every flag occurrence in order. -/
structure Args where
  positional : Array String
  /-- Flag occurrences as `(name, value)`, without the leading `--`; a switch has value `""`. -/
  flags : Array (String × String)
  deriving Repr, Inhabited

/-- Splits `argv`. `aliases` maps a short token to the flag name it stands for, as in
`[("-m", "note")]`. -/
def parse (argv : List String) (aliases : List (String × String) := []) : Args := Id.run do
  let mut positional : Array String := #[]
  let mut flags : Array (String × String) := #[]
  let mut rest := argv
  while true do
    match rest with
    | [] => break
    | token :: more =>
      let name? :=
        if token.startsWith "--" && token.length > 2 then some (token.drop 2).toString
        else aliases.lookup token
      match name? with
      | none => positional := positional.push token; rest := more
      | some name =>
        match more with
        | value :: tail =>
          if value.startsWith "--" then flags := flags.push (name, ""); rest := more
          else flags := flags.push (name, value); rest := tail
        | [] => flags := flags.push (name, ""); rest := []
  { positional, flags }

/-- Every value given for `name`, in the order the flags appeared. -/
def Args.all (args : Args) (name : String) : Array String :=
  args.flags.filterMap fun (flag, value) => if flag == name then some value else none

/-- The value of `name`; the last occurrence wins, so a later flag overrides an earlier one. -/
def Args.get? (args : Args) (name : String) : Option String := (args.all name).back?

def Args.getD (args : Args) (name fallback : String) : String := (args.get? name).getD fallback

/-- The value of `name`, or `fallback` when it is absent. Unlike `getD`, a flag given without a
value is an error rather than an empty string — `--data` with nothing after it is a mistake, not
a request for the empty path. -/
def Args.valueD (args : Args) (name fallback : String) : Result String :=
  match args.get? name with
  | none => pure fallback
  | some "" => throw <| .configuration s!"--{name} needs a value"
  | some value => pure value

/-- Whether `name` was given at all, with or without a value. -/
def Args.isSet (args : Args) (name : String) : Bool := (args.get? name).isSome

/-- The value of `name`, failing when it is absent or empty rather than defaulting. -/
def Args.require (args : Args) (name usage : String) : Result String :=
  match args.get? name with
  | some value =>
    if value.isEmpty then throw <| .configuration s!"--{name} needs a value ({usage})"
    else pure value
  | none => throw <| .configuration s!"--{name} is required ({usage})"

/-- Parses a decimal like `0.2` via the JSON number grammar. -/
def parseFloat? (s : String) : Option Float :=
  match Lean.Json.parse s with
  | .ok json => json.getNum?.toOption.map (·.toFloat)
  | .error _ => none

/-- The value of `name` as a natural number, failing when it is present but not a number. -/
def Args.nat? (args : Args) (name : String) : Result (Option Nat) :=
  match args.get? name with
  | none => pure none
  | some value => match value.toNat? with
    | some n => pure (some n)
    | none => throw <| .configuration s!"--{name} expects a whole number, got '{value}'"

def Args.natD (args : Args) (name : String) (fallback : Nat) : Result Nat :=
  return (← args.nat? name).getD fallback

/-- The value of `name` as a decimal, failing when it is present but not a number. -/
def Args.float? (args : Args) (name : String) : Result (Option Float) :=
  match args.get? name with
  | none => pure none
  | some value => match parseFloat? value with
    | some x => pure (some x)
    | none => throw <| .configuration s!"--{name} expects a number, got '{value}'"

def Args.floatD (args : Args) (name : String) (fallback : Float) : Result Float :=
  return (← args.float? name).getD fallback

end Alaya.Cli
