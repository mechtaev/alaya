import Test.Framework
import Alaya.Cas

/-! Feature 4 (in-process hashing): the pure SHA-256 against NIST vectors and, for block
boundaries and bulk input, cross-checked against the system checksum tool. -/

namespace CasTests.Sha256

open Testing
open Alaya.Cas

private def vectors : Array (String × String) := #[
  ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
  ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
  ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
   "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
  ("The quick brown fox jumps over the lazy dog",
   "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")]

/-- The digest the system's checksum tool assigns to `bytes`, via a scratch file. -/
private def systemDigest (bytes : ByteArray) : TestM String := do
  let path := (← scratch) / "input.bin"
  IO.FS.writeBinFile path bytes
  let run (cmd : String) (args : Array String) : IO (Option String) := do
    match ← (IO.Process.output { cmd, args }).toBaseIO with
    | .ok out => pure (if out.exitCode == 0 then some (out.stdout.take 64).toString else none)
    | .error _ => pure none
  match ← run "shasum" #["-a", "256", path.toString] with
  | some digest => pure digest
  | none =>
    match ← run "sha256sum" #[path.toString] with
    | some digest => pure digest
    | none => fail "no system checksum tool available"

def suite : Suite := Testing.suite "sha256" #[
  test "nist vectors" do
    for (input, expected) in vectors do
      assertEqual s!"sha256({input.take 12}...)" (Sha256.sumHex input.toUTF8) expected,

  test "padding boundaries match the system tool" do
    -- Every interesting length around the 64-byte block and 56-byte padding thresholds.
    for length in [0, 1, 54, 55, 56, 57, 63, 64, 65, 127, 128, 129, 1000] do
      let bytes := deterministicBytes (seed := length + 1) length
      assertEqual s!"length {length}" (Sha256.sumHex bytes) (← systemDigest bytes),

  test "bulk input matches the system tool" do
    let bytes := deterministicBytes (seed := 42) 262144
    assertEqual "256KiB digest" (Sha256.sumHex bytes) (← systemDigest bytes)
]

end CasTests.Sha256
