/-!
A pure, in-process SHA-256 (FIPS 180-4).

The content-addressed store hashes every blob it touches, so hashing must not cost a process
spawn per object the way shelling out to `sha256sum` does; a pure function is also trivially
safe to run from concurrently hashing capture workers.
-/

namespace Alaya.Cas.Sha256

private def k : Array UInt32 := #[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

private def initial : Array UInt32 := #[
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

@[inline] private def rotr (x : UInt32) (n : UInt32) : UInt32 :=
  (x >>> n) ||| (x <<< (32 - n))

/-- The big-endian word at `offset`; the caller guarantees four bytes are available. -/
@[inline] private def word (bytes : ByteArray) (offset : Nat) : UInt32 :=
  (bytes.get! offset).toUInt32 <<< 24 ||| (bytes.get! (offset + 1)).toUInt32 <<< 16 |||
  (bytes.get! (offset + 2)).toUInt32 <<< 8 ||| (bytes.get! (offset + 3)).toUInt32

private def processBlock (state : Array UInt32) (bytes : ByteArray) (offset : Nat) :
    Array UInt32 := Id.run do
  let mut w : Array UInt32 := Array.emptyWithCapacity 64
  for i in [0:16] do
    w := w.push (word bytes (offset + 4 * i))
  for i in [16:64] do
    let w15 := w[i - 15]!
    let w2 := w[i - 2]!
    let s0 := rotr w15 7 ^^^ rotr w15 18 ^^^ (w15 >>> 3)
    let s1 := rotr w2 17 ^^^ rotr w2 19 ^^^ (w2 >>> 10)
    w := w.push (w[i - 16]! + s0 + w[i - 7]! + s1)
  let mut a := state[0]!
  let mut b := state[1]!
  let mut c := state[2]!
  let mut d := state[3]!
  let mut e := state[4]!
  let mut f := state[5]!
  let mut g := state[6]!
  let mut h := state[7]!
  for i in [0:64] do
    let s1 := rotr e 6 ^^^ rotr e 11 ^^^ rotr e 25
    let ch := (e &&& f) ^^^ (~~~e &&& g)
    let temp1 := h + s1 + ch + k[i]! + w[i]!
    let s0 := rotr a 2 ^^^ rotr a 13 ^^^ rotr a 22
    let maj := (a &&& b) ^^^ (a &&& c) ^^^ (b &&& c)
    let temp2 := s0 + maj
    h := g
    g := f
    f := e
    e := d + temp1
    d := c
    c := b
    b := a
    a := temp1 + temp2
  return #[state[0]! + a, state[1]! + b, state[2]! + c, state[3]! + d,
           state[4]! + e, state[5]! + f, state[6]! + g, state[7]! + h]

/-- The final padded block(s): the message tail, `0x80`, zeros to 56 mod 64, and the
big-endian 64-bit bit length of the whole message. -/
private def finalBlocks (messageLength : Nat) (tail : ByteArray) : ByteArray := Id.run do
  let mut padded := tail.push 0x80
  while padded.size % 64 != 56 do
    padded := padded.push 0
  let bitLength := 8 * messageLength
  for i in [0:8] do
    padded := padded.push (UInt8.ofNat ((bitLength >>> (8 * (7 - i))) % 256))
  return padded

private def nibbleChar (n : Nat) : Char :=
  if n < 10 then Char.ofNat (48 + n) else Char.ofNat (87 + n)

private def toHex (state : Array UInt32) : String := Id.run do
  let mut hex := ""
  for wrd in state do
    for j in [0:8] do
      hex := hex.push (nibbleChar ((wrd >>> UInt32.ofNat (28 - 4 * j)).toNat % 16))
  return hex

/-- The lowercase hex SHA-256 digest of `bytes`. -/
def sumHex (bytes : ByteArray) : String := Id.run do
  let fullBlocks := bytes.size / 64
  let mut state := initial
  for i in [0:fullBlocks] do
    state := processBlock state bytes (64 * i)
  let padded := finalBlocks bytes.size (bytes.extract (64 * fullBlocks) bytes.size)
  for i in [0:padded.size / 64] do
    state := processBlock state padded (64 * i)
  return toHex state

end Alaya.Cas.Sha256
