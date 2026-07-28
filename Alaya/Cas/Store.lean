import Std.Data.HashSet
import Alaya.Error
import Alaya.Cas.Core
import Alaya.Cas.Sha256

/-!
The on-disk store: blobs under `blobs/`, plus named refs, per-workspace bookkeeping
(`cache/`, `checkouts/`), and a mark-and-sweep garbage collector rooted at the refs.
-/

namespace Alaya.Cas

/-- Counters describing the work a store has done, for observability and for tests that
assert incrementality ("the second capture hashed zero bytes"). -/
structure Metrics where
  /-- Bytes run through SHA-256 by `putBytes`. -/
  bytesHashed : Nat := 0
  /-- Blobs written because they were not yet present. -/
  blobsWritten : Nat := 0
  /-- Blobs whose content was already stored. -/
  blobsReused : Nat := 0
  /-- Files whose hash was taken from the stat cache instead of re-hashing. -/
  cacheHits : Nat := 0
  /-- Files that had to be read and hashed during capture. -/
  cacheMisses : Nat := 0
  /-- Files written into a destination by materialize. -/
  filesWritten : Nat := 0
  /-- Paths deleted from a destination by incremental materialize. -/
  filesDeleted : Nat := 0
  deriving BEq, Repr, Inhabited

/-- A handle to an on-disk content-addressed store. -/
structure Store where
  root : System.FilePath
  /-- Makes concurrently created temp-file names unique within this process. -/
  counter : IO.Ref Nat
  metricsRef : IO.Ref Metrics

private def io (action : IO α) : Result α :=
  Result.fromIO Error.storage action

/-- Blobs fan out by the first two hex characters, git-style, to keep directories small. -/
private def blobPath (store : Store) (hash : Hash) : System.FilePath :=
  store.root / "blobs" / (hash.hex.take 2).toString / hash.hex

namespace Store

/-- Opens (creating if needed) a content-addressed store rooted at `root`. -/
def create (root : System.FilePath) : Result Store := io do
  for directory in ["blobs", "tmp", "refs", "cache", "checkouts"] do
    IO.FS.createDirAll (root / directory)
  let counter ← IO.mkRef 0
  let metricsRef ← IO.mkRef ({} : Metrics)
  pure { root, counter, metricsRef }

def metrics (store : Store) : Result Metrics :=
  io store.metricsRef.get

def resetMetrics (store : Store) : Result Unit :=
  io <| store.metricsRef.modify fun _ => {}

/-- Applies an update to the store's metric counters (atomic; callable from any thread). -/
def recordMetrics (store : Store) (update : Metrics -> Metrics) : IO Unit :=
  store.metricsRef.modify update

/-- Writes `bytes` at `destination` atomically: to a unique temp file, then rename, so a
crash never leaves a half-written file at its final path and concurrent writers of identical
content are benign (rename replaces atomically). -/
def atomicWrite (store : Store) (destination : System.FilePath) (bytes : ByteArray) :
    IO Unit := do
  let suffix ← store.counter.modifyGet fun n => (n, n + 1)
  let temporary := store.root / "tmp" / s!"{suffix}-{← IO.monoNanosNow}.tmp"
  IO.FS.writeBinFile temporary bytes
  IO.FS.createDirAll (destination.parent.getD store.root)
  IO.FS.rename temporary destination

/-- Stores `bytes` under their content address, returning it. A no-op — no writes at all —
if the blob already exists. Safe to call from concurrent tasks. -/
def putBytes (store : Store) (bytes : ByteArray) : Result Hash := io do
  let hash : Hash := ⟨Sha256.sumHex bytes⟩
  recordMetrics store fun m => { m with bytesHashed := m.bytesHashed + bytes.size }
  let destination := blobPath store hash
  if ← destination.pathExists then
    recordMetrics store fun m => { m with blobsReused := m.blobsReused + 1 }
    return hash
  atomicWrite store destination bytes
  recordMetrics store fun m => { m with blobsWritten := m.blobsWritten + 1 }
  pure hash

/-- The on-disk location of the blob at `hash` — the source path for clone
materialization. The file exists only if the blob has been stored. -/
def blobFile (store : Store) (hash : Hash) : System.FilePath :=
  blobPath store hash

/-- Reads the blob at `hash`, or `none` if it is absent. -/
def getBytes (store : Store) (hash : Hash) : Result (Option ByteArray) := io do
  let path := blobPath store hash
  if ← path.pathExists then pure (some (← IO.FS.readBinFile path)) else pure none

/-- Whether the blob at `hash` is present. -/
def hasBytes (store : Store) (hash : Hash) : Result Bool := io do
  (blobPath store hash).pathExists

/-- Serializes and stores a directory object, returning its content address. -/
def putTree (store : Store) (tree : Tree) : Result Hash :=
  store.putBytes tree.toJson.compress.toUTF8

/-- Loads the directory object stored at `hash`. -/
def getTree (store : Store) (hash : Hash) : Result Tree := do
  let some bytes ← store.getBytes hash
    | throw <| .storage s!"missing tree {hash.hex}"
  let some text := String.fromUTF8? bytes
    | throw <| .storage s!"tree {hash.hex} is not valid UTF-8"
  let json ← Result.fromExcept Error.storage (Lean.Json.parse text)
  Result.fromExcept Error.storage (Tree.fromJson json)

/-! ## Refs

Named, mutable pointers into the immutable store — how a snapshot survives being someone's
"latest" without the caller having to persist loose hashes, and the roots the garbage
collector preserves. -/

def validRefName (name : String) : Bool :=
  !name.isEmpty && name != "." && name != ".." &&
    name.all fun c => c.isAlphanum || c == '-' || c == '_' || c == '.'

private def checkRefName (name : String) : Result Unit :=
  if validRefName name then pure ()
  else throw <| .storage s!"invalid ref name: {name}"

/-- Points ref `name` at `hash`, creating or atomically replacing it. -/
def setRef (store : Store) (name : String) (hash : Hash) : Result Unit := do
  checkRefName name
  io <| atomicWrite store (store.root / "refs" / name) hash.hex.toUTF8

def getRef? (store : Store) (name : String) : Result (Option Hash) := do
  checkRefName name
  let path := store.root / "refs" / name
  if !(← io path.pathExists) then return none
  let hex := (← io (IO.FS.readFile path)).trimAscii.toString
  if !validHex hex then throw <| .storage s!"corrupt ref {name}: {hex}"
  pure (some ⟨hex⟩)

/-- Removes ref `name`; succeeds whether or not it existed. -/
def deleteRef (store : Store) (name : String) : Result Unit := do
  checkRefName name
  let path := store.root / "refs" / name
  if ← io path.pathExists then io (IO.FS.removeFile path)

def listRefs (store : Store) : Result (Array (String × Hash)) := do
  let entries ← io (store.root / "refs").readDir
  let refs ← entries.filterMapM fun entry => do
    match ← store.getRef? entry.fileName with
    | some hash => pure (some (entry.fileName, hash))
    | none => pure none
  pure (refs.qsort fun a b => compare a.1 b.1 == .lt)

/-! ## Garbage collection -/

structure GcStats where
  keptBlobs : Nat := 0
  deletedBlobs : Nat := 0
  deriving BEq, Repr, Inhabited

/-- Marks `hash` and, when it parses as a tree, everything reachable from it. Missing or
unparseable objects are treated as leaves rather than errors: marking too much is safe,
failing a collection over one corrupt object is not. -/
private partial def markFrom (store : Store) (marked : IO.Ref (Std.HashSet String))
    (hash : Hash) (isTree : Bool) : Result Unit := do
  let seen ← io <| marked.modifyGet fun set => (set.contains hash.hex, set.insert hash.hex)
  if seen || !isTree then return ()
  let some bytes ← store.getBytes hash | return ()
  let some text := String.fromUTF8? bytes | return ()
  let .ok json := Lean.Json.parse text | return ()
  let .ok tree := Tree.fromJson json | return ()
  for entry in tree.entries do
    markFrom store marked entry.hash (entry.type == .directory)

/-- Deletes every blob not reachable from a ref, and clears leftover temp files. Snapshots
you want to survive a collection must be pinned by a ref. -/
def gc (store : Store) : Result GcStats := do
  let marked ← io (IO.mkRef ({} : Std.HashSet String))
  for (_, hash) in ← store.listRefs do
    markFrom store marked hash true
  let markedSet ← io marked.get
  let mut stats : GcStats := {}
  for fanout in ← io (store.root / "blobs").readDir do
    if ← io fanout.path.isDir then
      for blob in ← io fanout.path.readDir do
        if markedSet.contains blob.fileName then
          stats := { stats with keptBlobs := stats.keptBlobs + 1 }
        else
          io (IO.FS.removeFile blob.path)
          stats := { stats with deletedBlobs := stats.deletedBlobs + 1 }
  for leftover in ← io (store.root / "tmp").readDir do
    io (IO.FS.removeFile leftover.path)
  pure stats

end Store
end Alaya.Cas
