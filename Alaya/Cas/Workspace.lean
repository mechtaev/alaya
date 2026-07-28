import Std.Data.HashMap
import Std.Data.HashSet
import Alaya.Cas.Store

/-!
Moving real directories in and out of the store.

`snapshot` captures a directory as a Merkle tree: a stat cache makes unchanged files free to
re-capture, hashing fans out over dedicated threads, ignore rules prune the walk, and symlinks
and executable bits are recorded as first-class entry types. `materialize` writes a snapshot
back out, diffing against the destination's previous checkout so only changed paths are
touched, with content delivered by copy, hardlink, or (APFS/reflink) clone.
-/

namespace Alaya.Cas

private def io (action : IO α) : Result α :=
  Result.fromIO Error.storage action

/-- How symlinks encountered during capture are handled. -/
inductive SymlinkPolicy where
  /-- Record the link itself (target string), so restore reproduces the link. -/
  | capture
  /-- Fail the capture: snapshots must not contain links. -/
  | reject
  deriving BEq, Repr, Inhabited

structure CaptureConfig where
  /-- Skips every file or directory for which this returns true; receives the `/`-separated
  tree-relative path. A skipped directory is pruned without being read. See `ignoring` for a
  pattern-based helper. -/
  ignore : String -> Bool := fun _ => false
  /-- Reuse hashes for files whose size and mtime are unchanged since the previous capture of
  the same directory, instead of re-reading and re-hashing them. -/
  statCache : Bool := true
  /-- Number of dedicated hashing threads a capture may fan out over. -/
  concurrency : Nat := 8
  symlinks : SymlinkPolicy := .capture
  /-- Detect executable files (one `find` sweep per capture) and record them as
  `.executable` entries so restore can reproduce the bit. -/
  execBits : Bool := true

/-- How materialize delivers blob content into the destination. Both modes yield checkouts
that are safe to edit in place — the workflow agent workspaces need. -/
inductive LinkMode where
  /-- Write an independent copy of the bytes. Always works; deterministic permissions. -/
  | copy
  /-- Copy-on-write clone (`cp -c`, APFS/reflink): instant, space-free until modified, and
  safe to edit. Fails on filesystems without clone support. -/
  | clone
  deriving BEq, Repr, Inhabited

/-- What a full (non-incremental) materialize does when the destination is non-empty and not
a checkout this store created. -/
inductive OnExisting where
  | replace
  | error
  deriving BEq, Repr, Inhabited

structure MaterializeConfig where
  /-- Diff against the destination's recorded checkout and only touch changed paths. Falls
  back to a full write when there is no usable record. -/
  incremental : Bool := true
  /-- Re-capture the destination before an incremental apply, and fall back to a full write
  unless it still matches its record exactly.

  On by default because the record goes stale the moment anything else writes to the
  destination — an agent's own commands, a test overlay, a `rm -rf` and a fresh checkout of a
  different state — and an incremental apply against a stale record silently leaves a
  destination that is not the snapshot it claims to be. Turn it off only where the destination
  is known to be untouched since the last materialize. -/
  verify : Bool := true
  linkMode : LinkMode := .copy
  onExisting : OnExisting := .replace

/-! ## Ignore patterns -/

private def globComponent (pattern component : String) : Bool :=
  match pattern.splitOn "*" with
  | [exact] => component == exact
  | [before, after] =>
    decide (component.length >= before.length + after.length) &&
      component.startsWith before && component.endsWith after
  | _ => false

/-- A gitignore-flavoured matcher for `CaptureConfig.ignore`. Rules:
- `name` (no slash) skips any file or directory component equal to it; one `*` wildcard is
  supported, so `*.log` skips by extension.
- `dir/` (trailing slash) skips the directory at that relative path and its subtree.
- `a/b` (embedded slash) skips exactly that relative path and anything below it. -/
def ignoring (patterns : Array String) : String -> Bool := fun path =>
  patterns.any fun pattern =>
    if pattern.endsWith "/" then
      s!"{path}/" == pattern || path.startsWith pattern
    else if pattern.any (· == '/') then
      path == pattern || path.startsWith s!"{pattern}/"
    else
      (path.splitOn "/").any fun component => globComponent pattern component

/-! ## Shared helpers -/

private def runCommand (cmd : String) (args : Array String) : IO String := do
  let out ← IO.Process.output { cmd, args }
  if out.exitCode != 0 then
    throw <| IO.userError s!"{cmd} failed: {out.stderr}"
  pure out.stdout

/-- Resolves `directory` and refuses to proceed when it overlaps the store root: capturing
the store would race its own writes, and materializing over it would destroy it. -/
private def resolveDisjoint (store : Store) (directory : System.FilePath) (verb : String) :
    Result System.FilePath := do
  let root ← io (IO.FS.realPath store.root)
  let target ← io (IO.FS.realPath directory)
  if root == target || root.toString.startsWith s!"{target.toString}/" ||
      target.toString.startsWith s!"{root.toString}/" then
    throw <| .storage s!"cannot {verb} {target}: it overlaps the store at {root}"
  pure target

/-- The store-side bookkeeping file for a workspace directory, keyed by its resolved path so
distinct workspaces never share state. -/
private def workspaceKey (kind : String) (store : Store) (workspace : System.FilePath) :
    System.FilePath :=
  store.root / kind / Sha256.sumHex workspace.toString.toUTF8

/-- Removes whatever sits at `target` — file, symlink (not followed), or directory tree.
Succeeds if nothing is there. -/
private def removeExisting (target : System.FilePath) : IO Unit := do
  match ← target.symlinkMetadata.toBaseIO with
  | .error _ => pure ()
  | .ok metadata =>
    if metadata.type == .dir then IO.FS.removeDirAll target
    else IO.FS.removeFile target

private def executableRights : IO.FileRight := {
  user := { read := true, write := true, execution := true }
  group := { read := true, execution := true }
  other := { read := true, execution := true }
}

private def regularRights : IO.FileRight := {
  user := { read := true, write := true }
  group := { read := true }
  other := { read := true }
}

/-! ## Capture -/

private structure RawFile where
  relPath : String
  absPath : System.FilePath
  size : Nat
  mtime : IO.FS.SystemTime
  executable : Bool
  deriving Inhabited

private inductive RawEntry where
  | fileRef (name : String) (index : Nat)
  | link (name : String) (target : String)
  | dir (name : String) (children : Array RawEntry)

/-- One `find` sweep collecting the tree-relative paths of executable regular files, since
Lean's in-process `Metadata` does not expose permission bits. -/
private def findExecutables (source : System.FilePath) : Result (Std.HashSet String) := io do
  let out ← runCommand "find" #[source.toString, "-type", "f", "-perm", "-100"]
  let sourcePrefix := s!"{source.toString}/"
  pure <| (out.splitOn "\n").foldl (init := {}) fun set line =>
    if line.startsWith sourcePrefix then
      set.insert (line.drop sourcePrefix.length).toString
    else set

private partial def walk (config : CaptureConfig) (execSet : Std.HashSet String)
    (base : System.FilePath) (relative : String) (files : Array RawFile) :
    Result (Array RawEntry × Array RawFile) := do
  let directory := if relative.isEmpty then base else base / (relative : System.FilePath)
  let children ← io directory.readDir
  let sorted := children.qsort fun a b => compare a.fileName b.fileName == .lt
  let mut entries : Array RawEntry := #[]
  let mut files := files
  for child in sorted do
    let name := child.fileName
    let relPath := if relative.isEmpty then name else s!"{relative}/{name}"
    if config.ignore relPath then continue
    let metadata ← io child.path.symlinkMetadata
    match metadata.type with
    | .symlink =>
      match config.symlinks with
      | .reject => throw <| .storage s!"cannot capture symlink {relPath}"
      | .capture =>
        let target ← io (runCommand "readlink" #[child.path.toString])
        entries := entries.push (.link name target.trimAscii.toString)
    | .dir =>
      let (sub, updated) ← walk config execSet base relPath files
      files := updated
      entries := entries.push (.dir name sub)
    | .other =>
      -- A fifo or socket cannot be captured (reading one can block forever).
      throw <| .storage s!"cannot capture special file {relPath}"
    | .file =>
      entries := entries.push (.fileRef name files.size)
      files := files.push {
        relPath, absPath := child.path, size := metadata.byteSize.toNat
        mtime := metadata.modified, executable := execSet.contains relPath
      }
  pure (entries, files)

private structure CacheEntry where
  size : Nat
  sec : Int
  nsec : Nat
  hash : String

/-- Loads the stat cache for a workspace: hashes recorded by the previous capture, plus the
cache file's own mtime. An entry is only trusted for a file whose mtime is strictly older
than the cache file (the "racy" rule): a file modified in the same instant the cache was
written could carry a stale hash while matching size and mtime. -/
private def loadCache (store : Store) (source : System.FilePath) :
    Result (Std.HashMap String CacheEntry × Option IO.FS.SystemTime) := do
  let path := workspaceKey "cache" store source
  if !(← io path.pathExists) then return ({}, none)
  let writtenAt := (← io path.symlinkMetadata).modified
  let text ← io (IO.FS.readFile path)
  let parsed : Except String (Std.HashMap String CacheEntry) := do
    let json ← Lean.Json.parse text
    let array ← json.getArr?
    array.foldlM (init := {}) fun map value => do
      let path ← value.getObjVal? "path" >>= Lean.Json.getStr?
      let size ← value.getObjVal? "size" >>= Lean.Json.getNat?
      let sec ← value.getObjVal? "sec" >>= Lean.Json.getInt?
      let nsec ← value.getObjVal? "nsec" >>= Lean.Json.getNat?
      let hash ← value.getObjVal? "hash" >>= Lean.Json.getStr?
      pure (map.insert path { size, sec, nsec, hash })
  match parsed with
  | .ok entries => pure (entries, some writtenAt)
  | .error _ => pure ({}, none)  -- a corrupt cache costs a re-hash, never a failure

private def saveCache (store : Store) (source : System.FilePath) (files : Array RawFile)
    (hashes : Array Hash) : Result Unit := io do
  let json := Lean.Json.arr <| files.mapIdx fun index file =>
    Lean.Json.mkObj [
      ("path", file.relPath), ("size", Lean.toJson file.size),
      ("sec", Lean.toJson file.mtime.sec), ("nsec", Lean.toJson file.mtime.nsec.toNat),
      ("hash", hashes[index]!.hex)
    ]
  store.atomicWrite (workspaceKey "cache" store source) json.compress.toUTF8

private def chunkInto (items : Array α) (chunks : Nat) : Array (Array α) := Id.run do
  let chunks := max 1 chunks
  let size := max 1 ((items.size + chunks - 1) / chunks)
  let mut out := #[]
  let mut i := 0
  while i < items.size do
    out := out.push (items.extract i (min items.size (i + size)))
    i := i + size
  return out

/-- Hashes every file, drawing on the stat cache first and fanning the misses out over
dedicated threads (each request is disk plus CPU work, so pool workers would starve). -/
private def hashFiles (store : Store) (config : CaptureConfig) (source : System.FilePath)
    (files : Array RawFile) : Result (Array Hash) := do
  let (cache, cacheTime?) ←
    if config.statCache then loadCache store source
    else pure (({} : Std.HashMap String CacheEntry), none)
  let mut hashes : Array (Option Hash) := .replicate files.size none
  let mut misses : Array Nat := #[]
  for index in [0:files.size] do
    let file := files[index]!
    let cached? : Option String := do
      let writtenAt ← cacheTime?
      let entry ← cache.get? file.relPath
      if entry.size == file.size && entry.sec == file.mtime.sec &&
          entry.nsec == file.mtime.nsec.toNat && compare file.mtime writtenAt == .lt then
        pure entry.hash
      else none
    match cached? with
    | some hex =>
      -- A collected blob must not satisfy a hit, or capture would return a tree whose
      -- content cannot be read back.
      if ← store.hasBytes ⟨hex⟩ then
        hashes := hashes.set! index (some ⟨hex⟩)
        io <| store.recordMetrics fun m => { m with cacheHits := m.cacheHits + 1 }
      else
        misses := misses.push index
    | none =>
      misses := misses.push index
  if !misses.isEmpty then
    io <| store.recordMetrics fun m => { m with cacheMisses := m.cacheMisses + misses.size }
    let workers ← io <| (chunkInto misses config.concurrency).toList.mapM fun chunk =>
      BaseIO.asTask (prio := .dedicated) do
        let work : Result (Array (Nat × Hash)) := chunk.mapM fun index => do
          let bytes ← io (IO.FS.readBinFile files[index]!.absPath)
          pure (index, ← store.putBytes bytes)
        work.toBaseIO
    for task in workers do
      match task.get with
      | .ok pairs =>
        for (index, hash) in pairs do
          hashes := hashes.set! index (some hash)
      | .error error => throw error
  files.mapIdxM fun index _ => do
    let some hash := hashes[index]! | throw <| .storage "internal: file left unhashed"
    pure hash

private partial def buildTree (store : Store) (files : Array RawFile) (hashes : Array Hash)
    (entries : Array RawEntry) : Result Hash := do
  let built ← entries.mapM fun entry => do
    match entry with
    | .fileRef name index =>
      let type := if files[index]!.executable then EntryType.executable else EntryType.file
      pure ({ name, type, hash := hashes[index]! } : Entry)
    | .link name target =>
      pure ({ name, type := .symlink, hash := ← store.putBytes target.toUTF8 } : Entry)
    | .dir name children =>
      pure ({ name, type := .directory, hash := ← buildTree store files hashes children } : Entry)
  store.putTree (Tree.ofEntries built)

/-- Captures `directory` as a Merkle tree and returns the snapshot's content address (the
root tree hash). Pin it with `setRef` if it must survive `gc`. -/
def Store.snapshot (store : Store) (directory : System.FilePath)
    (config : CaptureConfig := {}) : Result Hash := do
  let source ← resolveDisjoint store directory "capture"
  let execSet ← if config.execBits then findExecutables source else pure {}
  let (shape, files) ← walk config execSet source "" #[]
  let hashes ← hashFiles store config source files
  let root ← buildTree store files hashes shape
  if config.statCache then saveCache store source files hashes
  pure root

/-! ## Diff -/

private partial def diffTrees (store : Store) (relative : String) (old new : Hash) :
    Result (Array Change) := do
  if old == new then return #[]
  let oldTree ← store.getTree old
  let newTree ← store.getTree new
  let join (name : String) : String :=
    if relative.isEmpty then name else s!"{relative}/{name}"
  let mut changes : Array Change := #[]
  let mut i := 0
  let mut j := 0
  while i < oldTree.entries.size || j < newTree.entries.size do
    let before? := oldTree.entries[i]?
    let after? := newTree.entries[j]?
    match before?, after? with
    | some before, after? =>
      if after?.all fun after => compare before.name after.name == .lt then
        changes := changes.push (.removed (join before.name) before.type)
        i := i + 1
      else if after?.all fun after => compare before.name after.name == .gt then
        let after := after?.get!
        changes := changes.push (.added (join after.name) after.type after.hash)
        j := j + 1
      else
        let after := after?.get!
        if before.type == .directory && after.type == .directory then
          if before.hash != after.hash then
            changes := changes ++ (← diffTrees store (join before.name) before.hash after.hash)
        else if before.type == .directory || after.type == .directory then
          changes := changes.push (.removed (join before.name) before.type)
          changes := changes.push (.added (join after.name) after.type after.hash)
        else if before.type != after.type || before.hash != after.hash then
          changes := changes.push (.modified (join after.name) after.type after.hash)
        i := i + 1
        j := j + 1
    | none, some after =>
      changes := changes.push (.added (join after.name) after.type after.hash)
      j := j + 1
    | none, none => pure ()
  pure changes

/-- Every difference between two snapshots, in traversal order. Identical subtrees are
skipped wholesale by hash, so the cost scales with the size of the change. -/
def Store.diff (store : Store) (old new : Hash) : Result (Array Change) :=
  diffTrees store "" old new

/-! ## Materialize -/

private def writeLeaf (store : Store) (config : MaterializeConfig) (type : EntryType)
    (hash : Hash) (target : System.FilePath) : Result Unit := do
  io (removeExisting target)
  match type with
  | .directory => throw <| .storage "internal: writeLeaf on a directory"
  | .symlink =>
    let some bytes ← store.getBytes hash
      | throw <| .storage s!"missing blob {hash.hex} for {target}"
    let some linkTarget := String.fromUTF8? bytes
      | throw <| .storage s!"symlink target {hash.hex} is not valid UTF-8"
    let _ ← io (runCommand "ln" #["-s", linkTarget, target.toString])
  | _ =>
    match config.linkMode with
    | .copy =>
      let some bytes ← store.getBytes hash
        | throw <| .storage s!"missing blob {hash.hex} for {target}"
      io (IO.FS.writeBinFile target bytes)
      io <| IO.setAccessRights target
        (if type == .executable then executableRights else regularRights)
    | .clone =>
      if !(← store.hasBytes hash) then
        throw <| .storage s!"missing blob {hash.hex} for {target}"
      let _ ← io (runCommand "cp" #["-c", (store.blobFile hash).toString, target.toString])
      io <| IO.setAccessRights target
        (if type == .executable then executableRights else regularRights)
  io <| store.recordMetrics fun m => { m with filesWritten := m.filesWritten + 1 }

private partial def writeSubtree (store : Store) (config : MaterializeConfig) (root : Hash)
    (destination : System.FilePath) : Result Unit := do
  io (IO.FS.createDirAll destination)
  let tree ← store.getTree root
  for entry in tree.entries do
    let target := destination / (entry.name : System.FilePath)
    if entry.type == .directory then
      writeSubtree store config entry.hash target
    else
      writeLeaf store config entry.type entry.hash target

private def readCheckout? (record : System.FilePath) : Result (Option Hash) := do
  if !(← io record.pathExists) then return none
  let hex := (← io (IO.FS.readFile record)).trimAscii.toString
  pure (if validHex hex then some ⟨hex⟩ else none)

/-- Applies `changes` to a destination previously materialized: removals first (a type
change arrives as a removal plus an addition), then additions and modifications. -/
private def applyChanges (store : Store) (config : MaterializeConfig)
    (destination : System.FilePath) (changes : Array Change) : Result Unit := do
  for change in changes do
    if let .removed path _ := change then
      io (removeExisting (destination / (path : System.FilePath)))
      io <| store.recordMetrics fun m => { m with filesDeleted := m.filesDeleted + 1 }
  for change in changes do
    match change with
    | .removed _ _ => pure ()
    | .added path type hash | .modified path type hash =>
      let target := destination / (path : System.FilePath)
      io (IO.FS.createDirAll (target.parent.getD destination))
      if type == .directory then
        writeSubtree store config hash target
      else
        writeLeaf store config type hash target

/-- Writes the snapshot at `root` into `directory`, so its contents afterwards are exactly
the snapshot. A record of the checkout (keyed by the directory's resolved path) enables the
next materialize into the same directory to touch only changed paths. -/
def Store.materialize (store : Store) (root : Hash) (directory : System.FilePath)
    (config : MaterializeConfig := {}) : Result Unit := do
  io (IO.FS.createDirAll directory)
  let destination ← resolveDisjoint store directory "materialize into"
  let record := workspaceKey "checkouts" store destination
  let _ ← store.getTree root  -- fail before touching the destination if the snapshot is absent
  let previous? ← readCheckout? record
  let mut applied := false
  if config.incremental then
    if let some previous := previous? then
      let trusted ←
        if config.verify then
          let actual ← store.snapshot destination
          pure (actual == previous)
        else pure true
      if trusted then
        match ← (store.diff previous root).toBaseIO with
        | .ok changes =>
          applyChanges store config destination changes
          applied := true
        | .error _ => pure ()  -- e.g. the old tree was collected: fall back to a full write
  if !applied then
    if !(← io destination.readDir).isEmpty then
      if previous?.isNone && config.onExisting == .error then
        throw <| .storage s!"{destination} is not empty and not a checkout of this store"
      io (IO.FS.removeDirAll destination)
      io (IO.FS.createDirAll destination)
    writeSubtree store config root destination
  io <| store.atomicWrite record root.hex.toUTF8

/-- Restores the snapshot at `id` into `directory`; see `materialize`. -/
def Store.restore (store : Store) (id : Hash) (directory : System.FilePath)
    (config : MaterializeConfig := {}) : Result Unit :=
  store.materialize id directory config

/-! ## Pure path operations

Reading and editing snapshots without materializing anything — the basis for cheap
branching: fork a snapshot by writing to it, getting a new root back. -/

private partial def entryAt (store : Store) (treeHash : Hash) (components : List String) :
    Result (Option Entry) := do
  let tree ← store.getTree treeHash
  match components with
  | [] => pure none
  | [name] => pure (tree.find? name)
  | name :: rest =>
    match tree.find? name with
    | some entry =>
      if entry.type == .directory then entryAt store entry.hash rest else pure none
    | none => pure none

/-- The entry at a `/`-separated path within the snapshot at `root`, if present. -/
def Store.entryAt? (store : Store) (root : Hash) (path : String) : Result (Option Entry) := do
  if !safeRelativePath path then throw <| .storage s!"unsafe path: {path}"
  entryAt store root (path.splitOn "/")

/-- The content blob at `path` (for a symlink, its target string), or `none` when the path
is absent or names a directory. -/
def Store.readPath (store : Store) (root : Hash) (path : String) :
    Result (Option ByteArray) := do
  match ← store.entryAt? root path with
  | some entry =>
    if entry.type == .directory then pure none else store.getBytes entry.hash
  | none => pure none

private partial def writeAt (store : Store) (treeHash? : Option Hash)
    (components : List String) (type : EntryType) (blob : Hash) : Result Hash := do
  let tree ← match treeHash? with
    | some hash => store.getTree hash
    | none => pure Tree.empty
  match components with
  | [] => throw <| .storage "internal: empty path in writeAt"
  | [name] => store.putTree (tree.insert { name, type, hash := blob })
  | name :: rest =>
    let below? ← match tree.find? name with
      | some entry =>
        if entry.type == .directory then pure (some entry.hash)
        else throw <| .storage s!"{name} is not a directory"
      | none => pure none
    let below ← writeAt store below? rest type blob
    store.putTree (tree.insert { name, type := .directory, hash := below })

/-- Returns a new snapshot root equal to `root` with `bytes` at `path` (missing parent
directories are created); the store gains at most the new blob and the trees along the
path. `type` selects a regular, executable, or symlink entry. -/
def Store.writePath (store : Store) (root : Hash) (path : String) (bytes : ByteArray)
    (type : EntryType := .file) : Result Hash := do
  if type == .directory then throw <| .storage "writePath cannot write a directory"
  if !safeRelativePath path then throw <| .storage s!"unsafe path: {path}"
  let blob ← store.putBytes bytes
  writeAt store (some root) (path.splitOn "/") type blob

private partial def removeAt (store : Store) (treeHash : Hash) (components : List String) :
    Result Hash := do
  let tree ← store.getTree treeHash
  match components with
  | [] => throw <| .storage "internal: empty path in removeAt"
  | [name] => store.putTree (tree.erase name)
  | name :: rest =>
    match tree.find? name with
    | some entry =>
      if entry.type == .directory then
        let below ← removeAt store entry.hash rest
        store.putTree (tree.insert { name, type := .directory, hash := below })
      else pure treeHash
    | none => pure treeHash

/-- Returns a new snapshot root equal to `root` without `path`. Removing an absent path
returns the root unchanged. -/
def Store.removePath (store : Store) (root : Hash) (path : String) : Result Hash := do
  if !safeRelativePath path then throw <| .storage s!"unsafe path: {path}"
  removeAt store root (path.splitOn "/")

private partial def listInto (store : Store) (relative : String) (treeHash : Hash)
    (accumulated : Array (String × EntryType)) : Result (Array (String × EntryType)) := do
  let tree ← store.getTree treeHash
  tree.entries.foldlM (init := accumulated) fun accumulated entry => do
    let path := if relative.isEmpty then entry.name else s!"{relative}/{entry.name}"
    let accumulated := accumulated.push (path, entry.type)
    if entry.type == .directory then listInto store path entry.hash accumulated
    else pure accumulated

/-- Every path in the snapshot at `root` with its entry type, in depth-first canonical
order (directories precede their contents). -/
def Store.listPaths (store : Store) (root : Hash) : Result (Array (String × EntryType)) :=
  listInto store "" root #[]

end Alaya.Cas
