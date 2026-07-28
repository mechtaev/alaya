import Test.Framework
import Alaya

/-! Command-line parsing and the DGX Spark endpoint syntax. -/

namespace CliTests

open Testing
open Alaya

private def parse (argv : List String) : Cli.Args :=
  Cli.parse argv (aliases := [("-m", "note")])

private def endpoint (url : String) : Option Provider.Dgx.Endpoint :=
  (Provider.Dgx.Endpoint.ofUrl url).toOption

private def baseUrlOf (argv : List String) : Result (Option String) := do
  let options ← Provider.Options.ofArgs (Cli.parse argv)
  pure (options.dgxEndpoint?.map (·.baseUrl))

def argsSuite : Suite := suite "cli.args" #[
  test "positionals and flags interleave" do
    let args := parse ["commit", "abc", "dir", "--data", "d", "-m", "note text"]
    assertEqual "positional" args.positional #["commit", "abc", "dir"]
    assertEqual "data" (args.getD "data" "") "d"
    assertEqual "alias" (args.getD "note" "") "note text",

  test "a repeated flag keeps every value, and get? takes the last" do
    let args := parse ["--model", "a:1", "--model", "b:2", "--count", "4"]
    assertEqual "all" (args.all "model") #["a:1", "b:2"]
    assertEqual "last" (args.getD "model" "") "b:2"
    assertEqual "positional" args.positional #[],

  test "a flag before another flag, or at the end, is a valueless switch" do
    let args := parse ["--concurrent", "--count", "8"]
    assertEqual "switch" (args.getD "concurrent" "unset") ""
    assertEqual "isSet" (args.isSet "concurrent") true
    assertEqual "count" (args.getD "count" "") "8"
    assertEqual "trailing switch" ((parse ["--concurrent"]).isSet "concurrent") true,

  test "numeric flags report the flag name on bad input" do
    let args := parse ["--count", "x"]
    assertEqual "default" (← assertOk (args.natD "missing" 8)) 8
    assertError "count" (args.natD "count" 8) fun
      | .configuration m => m.startsWith "--count expects a whole number"
      | _ => false
    let temperature ← assertOk ((parse ["--temperature", "0.25"]).floatD "temperature" 0.0)
    assertEqual "float" temperature 0.25,

  test "a value-taking flag given without a value is an error" do
    assertEqual "absent" (← assertOk ((parse []).valueD "data" ".alaya")) ".alaya"
    assertEqual "given" (← assertOk ((parse ["--data", "d"]).valueD "data" ".alaya")) "d"
    assertError "switch" ((parse ["--data"]).valueD "data" ".alaya") fun
      | .configuration m => m == "--data needs a value"
      | _ => false,

  test "require fails when a flag is missing or empty" do
    assertError "missing" ((parse []).require "model" "hint") fun
      | .configuration m => m.startsWith "--model is required"
      | _ => false
    assertError "empty" ((parse ["--model"]).require "model" "hint") fun
      | .configuration m => m.startsWith "--model needs a value"
      | _ => false
]

def endpointSuite : Suite := suite "cli.endpoint" #[
  test "the default endpoint is the Spark's own address" do
    assertEqual "baseUrl" ({} : Provider.Dgx.Endpoint).baseUrl "http://10.42.0.1:8000/v1",

  test "a URL fills in only what it specifies" do
    assertEqual "full" ((endpoint "http://192.168.1.5:9000/v1").map (·.baseUrl))
      (some "http://192.168.1.5:9000/v1")
    assertEqual "host:port" ((endpoint "192.168.1.5:9000").map (·.baseUrl))
      (some "http://192.168.1.5:9000/v1")
    assertEqual "host only" ((endpoint "spark.local").map (·.baseUrl))
      (some "http://spark.local:8000/v1")
    assertEqual "https and path" ((endpoint "https://spark.local/openai/v1").map (·.baseUrl))
      (some "https://spark.local:8000/openai/v1")
    assertEqual "trailing slash" ((endpoint "http://spark.local:9000/").map (·.baseUrl))
      (some "http://spark.local:9000/v1"),

  test "a malformed URL is rejected" do
    assertEqual "no host" (endpoint ":9000").isSome false
    assertEqual "bad port" (endpoint "spark.local:http").isSome false
    assertEqual "empty" (endpoint "  ").isSome false,

  test "--port overrides the port from --url, and works on its own" do
    assertEqual "port only" (← assertOk (baseUrlOf ["--port", "9001"]))
      (some "http://10.42.0.1:9001/v1")
    assertEqual "url and port" (← assertOk (baseUrlOf ["--url", "spark.local:9000", "--port", "7000"]))
      (some "http://spark.local:7000/v1")
    assertEqual "neither" (← assertOk (baseUrlOf [])) none
    assertError "bad url" (baseUrlOf ["--url", ":9000"]) fun
      | .configuration m => m.startsWith "--url:"
      | _ => false,

  test "an unknown provider names the ones that exist" do
    assertError "unknown" (Provider.fromSpec "nope:x" 0.0) fun
      | .configuration m => m.startsWith "unknown provider: nope"
      | _ => false
    assertError "not a spec" (Provider.fromSpec "dgx" 0.0) fun
      | .configuration m => m.endsWith "(e.g. dgx:gpt-oss-120b)"
      | _ => false
]

def suites : Array Suite := #[argsSuite, endpointSuite]

end CliTests
